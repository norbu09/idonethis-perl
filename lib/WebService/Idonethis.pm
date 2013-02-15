package WebService::Idonethis;
use v5.010;
use strict;
use warnings;
use autodie;
use Moose;
use MooseX::Method::Signatures;
use WWW::Mechanize;
use JSON::Any;
use Carp qw(croak);
use POSIX qw(strftime);
use HTTP::Request;
use File::XDG;
use File::Spec;
use HTTP::Cookies;
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

Patches are extremely welcome. L<https://github.com/pfenwick/idonethis-perl>

=for Pod::Coverage BUILD

=cut

has agent    => (               is => 'rw' );
has user_url => (               is => 'rw' );
has user     => ( isa => 'Str', is => 'rw' );
has xdg      => (               is => 'rw' );

sub BUILD {
    my ($self, $args) = @_;

    my $agent = $self->agent;

    if (not $self->xdg) { 

        # XDG is used to figure out where to store cache and config
        # files. If not provided at initialisation time, we'll
        # mae our own.

        $self->xdg(File::XDG->new(name => 'webservice-idonethis-perl'));
    }

    # Theoretically these may get changed after login.
    $self->user    ( $args->{user} );
    $self->user_url( "https://idonethis.com/cal/$args->{user}/" );

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
        );

        $self->agent( $agent );

    }

    # Ping idonethis to see if we even need to login.

    # We're going to guess our user URL so we can do a get_day.

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

        if ($url !~ m{/cal/$args->{user}/?$}) {
            croak "Login to idonethis failed (unexpected URL $url)";
        }

        $self->user_url( $url );
        $self->user( $args->{user} );
    };

    return;

}

=method get_day

    my $dones = $idt->get_day("2012-01-01");

Gets the data for a given day. An array will be returned which is a
conversation from the JSON data structure used by idonethis. The
structure at the time of writing looks like this:

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

method get_day( Str $date) {
    my $url = $self->user_url . "dailydone?";

    $url .= "start=$date&end=$date";

    $self->agent->get($url);

    return $json->decode( $self->agent->content );
}

=method get_today

    my $dones = $idt->get_today;

This is a convenience method that calls L<get_day> using the current
(localtime) date as an argument.

=cut

method get_today() {
    my $today = strftime("%Y-%m-%d",localtime);

    return $self->get_day( $today );
}

=method set_done

    $idt->set_done( text => "Installed WebService::Idonethis" );
    $idt->set_done( date => '2013-01-01', text => "Drank coffee." );

Submits a done item to I<idonethis.com>.  The C<date> field is optional,
but the C<text> field is mandatory.  The current date (localtime) will
be used if no date is specified.

Returns nothing on success. Throws an exception on failure.

=cut

method set_done(
    Str :$date  ,
    Str :$text !
) {

    # TODO: Use real date objects.
    # TODO: Allow more arguments to be passed.

    my $now       = time();
    my $timestamp = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($now));

    $date ||= strftime("%Y-%m-%d", localtime($now));

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

    # XXX: This is wrong, and you should never do it, but it looks like
    # we have to send this has a header for idonethis to accept the request.

    $req->header (
        'X-CSRFToken' =>
            $self->agent->cookie_jar->{COOKIES}{'idonethis.com'}{'/'}{csrftoken}[1]
    );

    my $response = $self->agent->request( $req );

    # TODO: Check we die automatically on failed submission.

    return;
}

sub DEMOLISH {
    $_[0]->agent->cookie_jar->save;
}

=head1 SEE ALSO

L<http://privacygeek.blogspot.com.au/2013/02/reimplementing-idonethis-memory-service.html>

=cut

1;
