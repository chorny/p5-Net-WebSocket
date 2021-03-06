package Net::WebSocket::Handshake::Client;

=encoding utf-8

=head1 NAME

Net::WebSocket::Handshake::Client

=head1 SYNOPSIS

    my $hsk = Net::WebSocket::Handshake::Client->new(

        #required
        uri => 'ws://haha.test',

        #optional
        subprotocols => [ 'echo', 'haha' ],

        #optional, base 64 .. auto-created if not given
        key => '..',
    );

    #Includes only one trailing CRLF, so you can add additional headers
    my $txt = $hsk->create_header_text();

    my $b64 = $hsk->get_key();

    #Validates the value of the “Sec-WebSocket-Accept” header;
    #throws Net::WebSocket::X::BadAccept if not.
    $hsk->validate_accept_or_die($accent_value);

=cut

use strict;
use warnings;

use parent qw( Net::WebSocket::Handshake::Base );

use URI::Split ();

use Module::Load ();

use Net::WebSocket::Constants ();
use Net::WebSocket::X ();

sub new {
    my ($class, %opts) = @_;

    if (length $opts{'uri'}) {
        @opts{ 'uri_schema', 'uri_auth', 'uri_path', 'uri_query' } = URI::Split::uri_split($opts{'uri'});
    }

    if (!$opts{'uri_schema'} || ($opts{'uri_schema'} !~ m<\A(?:ws|http)s?\z>)) {
        die Net::WebSocket::X->create('BadArg', uri => $opts{'uri'});
    }

    if (!$opts{'uri_auth'}) {
        die Net::WebSocket::X->create('BadArg', uri => $opts{'uri'});
    }

    @opts{ 'uri_host', 'uri_port' } = split m<:>, $opts{'uri_auth'};

    $opts{'key'} ||= _create_key();

    return bless \%opts, $class;
}

sub _create_header_lines {
    my ($self) = @_;

    my $path = $self->{'uri_path'};

    if (!length $path) {
        $path = '/';
    }

    if (length $self->{'uri_query'}) {
        $path .= "?$self->{'uri_query'}";
    }

    return (
        "GET $path HTTP/1.1",
        "Host: $self->{'uri_host'}",

        #For now let’s assume no one wants any other Upgrade:
        #or Connection: values than the ones WebSocket requires.
        'Upgrade: websocket',
        'Connection: Upgrade',

        "Sec-WebSocket-Key: $self->{'key'}",
        'Sec-WebSocket-Version: ' . Net::WebSocket::Constants::PROTOCOL_VERSION(),

        $self->_encode_subprotocols(),

        ( $self->{'origin'} ? "Origin: $self->{'origin'}" : () ),

        #TODO: Support “extensions”
    );
}

sub validate_accept_or_die {
    my ($self, $received) = @_;

    my $should_be = $self->_get_accept();

    return if $received eq $should_be;

    #TODO
    die Net::WebSocket::X->create('BadAccept', $should_be, $received );
}

sub get_key {
    my ($self) = @_;

    return $self->{'key'};
}

sub _create_key {
    Module::Load::load('MIME::Base64') if !MIME::Base64->can('encode');
    Module::Load::load('Net::WebSocket::RNG') if !Net::WebSocket::RNG->can('get');

    my $b64 = MIME::Base64::encode_base64( Net::WebSocket::RNG::get()->bytes(16) );
    chomp $b64;

    return $b64;
}

1;
