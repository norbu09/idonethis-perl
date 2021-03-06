package WebService::Idonethis;
use v5.010;
use strict;
use warnings;
use autodie;
use Moo;
use WWW::Mechanize;
use JSON::Any;
use Carp qw(croak);
use POSIX qw(strftime);
use HTTP::Request;
use File::XDG;
use File::Spec;
use HTTP::Cookies;
use HTML::Entities qw(decode_entities);
use Try::Tiny;

my $json = JSON::Any->new;

# ABSTRACT: WebScraping pseudo-API for iDoneThis

# VERSION: Generated by DZP::OurPkg:Version

=head1 SYNOPSIS

    use WebService::Idonethis;

    my $idt = WebService::Idonethis->new(
        user => 'someuser',
        pass => 'somepass',
    );

    my $dones = $idt->get_day("2012-01-01");

    foreach my $item (@$dones) {
        say "* $item->{text}";
    }

    # Get items done today

    my $dones = $idt->get_today;

    # Submit a new done item.

    $idt->set_done(text => "Drank ALL the coffee!");

=head1 DESCRIPTION

This is an extremely bare-bones wrapper around the L<idonethis.com>
website that allows retrieving of what was done on a particular day.
It's only been tested with personal calendars. Patches are extremely
welcome.

This code was motivated by I<idonethis.com>'s most excellent (but now
defunct) memory service, which would send reminders as to what one
was doing a year ago by email.

The L<idonethis-memories> command included in this distribution is
a simple proof-of-concept that reimplements this service, and is suitable
for running as a cron job.

The L<idone> command included with this distribution allows you to submit
new done items from the command line.

Patches are extremely welcome. L<https://github.com/pjf/idonethis-perl>

=head1 FILES

Sessions are cached in your XDG cache directory as
'webservice-idonethis-perl'.

=for Pod::Coverage BUILD DEMOLISH

=for Pod::Coverage agent calendar user_url user xdg

=cut

has agent    => (               is => 'rw' );
has calendar => (               is => 'rw' );
has user_url => (               is => 'rw' );
has user     => (               is => 'rw' );
has xdg      => (               is => 'rw' );

sub BUILD {
    my ($self, $args) = @_;

    my $agent = $self->agent;

    if (not $self->xdg) { 

        # XDG is used to figure out where to store cache and config
        # files. If not provided at initialisation time, we'll
        # make our own.

        $self->xdg(File::XDG->new(name => 'webservice-idonethis-perl'));
    }

    # Theoretically these may get changed after login.
    $self->calendar( $args->{calendar} ? $args->{calendar} : $args->{user} );
    $self->user    ( $args->{user} );
    $self->user_url( "https://idonethis.com/cal/$self->calendar/" );

    if (not $agent) {

        # Initialise user-agent if none provided, storing cookies in
        # the xdg cache.

        my $xdg = $self->xdg;

        if (not -e $xdg->cache_home) {
            mkdir($xdg->cache_home);
        }

        my $user_cache = File::Spec->catfile( $xdg->cache_home, $self->user );

        if (not -e $user_cache) {
            mkdir($user_cache);
        }

        $agent = WWW::Mechanize->new(
            agent      => "perl/$], WebService::Idonethis/" . $self->VERSION,
            cookie_jar => HTTP::Cookies->new( file => File::Spec->catfile( $user_cache , "cookies") ),
            keep_alive => 1,
            stack_depth => 0, # Don't keep history
        );

        $self->agent( $agent );

    }

    # Ping idonethis to see if we even need to login.

    try {
        $self->get_today;   # Throws on failure
    }
    catch {
        # Our ping failed, so login instead.

        $agent->get( "https://idonethis.com/accounts/login/" );

        $agent->submit_form(
            form_id => 'register',
            fields => {
                username => $args->{user},
                password => $args->{pass},
            }
        );

        my $url = $agent->uri;

        if ($url =~ m{/login/?$}i) {
            # Bounced back to login screen. Login failed
            croak "Login to idonethis failed (wrong username/password?)";
        }
        elsif ($url =~ m{/home/?$}i) {
            # Taken to home-screen. Login successful, but we need to
            # chase our calendar link.

            my $cal = $args->{calendar};
            $agent->follow_link( text_regex => qr{\b$cal\b} );
        }
        elsif ($url !~ m{/cal/\w+/?$}) {
            # Oh noes! Where are we?
            croak "Login to idonethis failed (unexpected URL $url)";
        }

        # At this point, we *should* be on our calendar page.
        $url = $agent->uri;

        if ($url =~ m{/cal/(?<cal>[\w-]+)/?$}) {

            # Looks like a valid calendar! Remember our calendar
            # URL and username.

            $self->user_url( $url );
            $self->calendar( $+{cal} );
        }
        else {
            croak "Failed to navigate to idonethis calendar (found self at $url)";
        }

        # We used to save the cookie jar on destruction, but that
        # caused a hiccup with Moo. Now we save immediately after
        # login.

        $self->agent->cookie_jar->save();
    };

    return;

}

=method get_day

    my $dones = $idt->get_day("2012-01-01");

Gets the data for a given day. An array will be returned which is a
conversation from the JSON data structure used by idonethis. The
structure at the time of writing looks like this:

The 'text' field (and currently only the 'text' field) will have
HTML entities converted before it is returned. (eg, '&gt' -> '>')

    [
        {
            owner => 'some_user',
            avatar_url => '/site_media/blahblah/foo.png',
            modified => '2012-01-01T15:22:33.12345',
            calendar => {
                short_name => 'some_short_name', # usually owner name
                name => 'personal',
                type => 'PERSONAL',
            },
            created => '2012-01-01T15:22:33.12345',
            done_date => '2012-01-01',
            text => 'Wrote code to frobinate the foobar',
            nicest_name => 'some_user',
            type => 'dailydone',
            id => 12345
        },
        ...
    ]

=cut

sub get_day {
    my ($self, $date) = @_;

    return $self->get_range($date, $date);
}

=method get_today

    my $dones = $idt->get_today;

This is a convenience method that calls L</get_day> using the current
(localtime) date as an argument.

=cut

sub get_today {
    my ($self) = @_;
    my $today = strftime("%Y-%m-%d",localtime);

    return $self->get_day( $today );
}

=method get_range

    my $done = $idt->get_range('2012-01-01', 2012-01-31');

Gets everything done in a range of dates. Returns in the same
format at L</get_day> above.

=cut

sub get_range {

    my ($self, $start, $end) = @_;

    my $url = $self->user_url . "dailydone?";

    $url .= "start=$start&end=$end";

    $self->agent->get($url);

    # Decode JSON

    my $data = $json->decode( $self->agent->content );

    # Decode HTML entities.

    foreach my $record (@$data) {
        $record->{text} = decode_entities($record->{text}) if $record->{text};
    }

    return $data;
}

=method set_done

    $idt->set_done( text => "Installed WebService::Idonethis" );
    $idt->set_done( date => '2013-01-01', text => "Drank coffee." );

Submits a done item to I<idonethis.com>.  The C<date> field is optional,
but the C<text> field is mandatory.  The current date (localtime) will
be used if no date is specified.

Returns nothing on success. Throws an exception on failure.

=cut

sub set_done {

    my ($self, %args)  = @_;

    # TODO: Use real date objects.
    # TODO: Allow more arguments to be passed.

    my $now       = time();
    my $timestamp = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($now));

    my $date = $args{date} || strftime("%Y-%m-%d", localtime($now));
    my $text = $args{text} or croak "set_done requires a 'text' argument";

    my $done_json = $json->encode({
        calendar       => $self->user,
        owner          => $self->user,
        created        => $timestamp,
        modified       => $timestamp,
        done_date      => $date,
        text           => $text,
        total_comments => undef,
        total_likes    => undef,
        url            => undef,
    });

    # TODO: There's got to be a better way of doing JSON posts than this...

    my $req = HTTP::Request->new( 'POST', $self->user_url . "dailydone?" );
    $req->header ( 'Content-Type' => 'application/json' );
    $req->header ( 'Accept' => 'application/json, text/javascript, */*; q0.01' );
    $req->content( $done_json );

    # NOTE: This is wrong, and you should never do it, but it looks like
    # we have to send this header for idonethis to accept the request.

    $req->header (
        'X-CSRFToken' =>
            $self->agent->cookie_jar->{COOKIES}{'idonethis.com'}{'/'}{csrftoken}[1]
    );

    my $response = $self->agent->request( $req );

    # TODO: Check we die automatically on failed submission.

    return;
}

__PACKAGE__->meta->make_immutable;

=head1 BUGS

If a suitable cache location cannot be created on the filesystem, this class dies with
an error. See L<https://github.com/pjf/idonethis-perl/issues/7> for more details.

Other bugs may be present that are not listed in this documentation. See
L<https://github.com/pjf/idonethis-perl/issues> for a full list, or to submit your
own.

=head1 SEE ALSO

L<http://privacygeek.blogspot.com.au/2013/02/reimplementing-idonethis-memory-service.html>

=cut

1;
