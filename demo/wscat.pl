#!/usr/bin/env perl

use strict;
use warnings;
use autodie;

use Try::Tiny;

use HTTP::Response;
use IO::Select ();
use IO::Socket::INET ();
use Socket ();
use URI::Split ();

use FindBin;
use lib "$FindBin::Bin/../lib";

use Net::WebSocket::Endpoint::Client ();
use Net::WebSocket::Frame::binary ();
use Net::WebSocket::Frame::close  ();
use Net::WebSocket::Handshake::Client ();
use Net::WebSocket::Parser ();

use constant MAX_CHUNK_SIZE => 64000;

use constant CRLF => "\x0d\x0a";

use constant ERROR_SIGS => qw( INT HUP QUIT ABRT USR1 USR2 SEGV ALRM TERM );

run( @ARGV ) if !caller;

sub run {
    my ($uri) = @_;

    my ($uri_scheme, $uri_authority) = URI::Split::uri_split($uri);

    if (!$uri_scheme) {
        die "Need a URI!\n";
    }

    if ($uri_scheme !~ m<\Awss?\z>) {
        die sprintf "Invalid schema: “%s” ($uri)\n", $uri_scheme;
    }

    my $inet;

    my ($host, $port) = split m<:>, $uri_authority;

    if ($uri_scheme eq 'ws') {
        my $iaddr = Socket::inet_aton($host);

        $port ||= 80;
        my $paddr = Socket::pack_sockaddr_in( $port, $iaddr );

        socket( $inet, Socket::PF_INET(), Socket::SOCK_STREAM(), 0 );
        connect( $inet, $paddr );
    }
    elsif ($uri_scheme eq 'wss') {
        require IO::Socket::SSL;

        $inet = IO::Socket::SSL->new(
            PeerHost => $host,
            PeerPort => $port || 443,
            SSL_hostname => $host,
        );

        die "IO::Socket::SSL: [$!][$@]\n" if !$inet;
    }
    else {
        die "Unknown scheme ($uri_scheme) in URI: “$uri”";
    }

    my $buf_sr = _handshake_as_client( $inet, $uri );

    _mux_after_handshake( \*STDIN, \*STDOUT, $inet, $$buf_sr );

    exit 0;
}

sub _handshake_as_client {
    my ($inet, $uri) = @_;

    my $handshake = Net::WebSocket::Handshake::Client->new(
        uri => $uri,
    );

    my $hdr = $handshake->create_header_text();

    #Write out the client handshake.
    syswrite( $inet, $hdr . CRLF );

    my $handshake_ok;

    my $buf = q<>;

    #Read the server handshake.
    my $idx;
    while ( sysread $inet, $buf, MAX_CHUNK_SIZE, length $buf ) {
        $idx = index($buf, CRLF . CRLF);
        last if -1 != $idx;
    }

    my $hdrs_txt = substr( $buf, 0, $idx + 2 * length(CRLF), q<> );

    my $req = HTTP::Response->parse($hdrs_txt);

    my $code = $req->code();
    die "Must be 101, not “$code”" if $code != 101;

    my $upg = $req->header('upgrade');
    $upg =~ tr<A-Z><a-z>;
    die "“Upgrade” must be “websocket”, not “$upg”!" if $upg ne 'websocket';

    my $conn = $req->header('connection');
    $conn =~ tr<A-Z><a-z>;
    die "“Upgrade” must be “upgrade”, not “$conn”!" if $conn ne 'upgrade';

    my $accept = $req->header('Sec-WebSocket-Accept');
    $handshake->validate_accept_or_die($accept);

    return \$buf;
}

my $sent_ping;

sub _mux_after_handshake {
    my ($from_caller, $to_caller, $inet, $buf) = @_;

    my $parser = Net::WebSocket::Parser->new(
        $inet,
        $buf,
    );

    my $ept = Net::WebSocket::Endpoint::Client->new(
        out => $inet,
        parser => $parser,
    );

    for my $sig (ERROR_SIGS()) {
        $SIG{$sig} = sub {
            my ($the_sig) = @_;

            my $code = ($the_sig eq 'INT') ? 'SUCCESS' : 'ENDPOINT_UNAVAILABLE';

            my $frame = Net::WebSocket::Frame::close->new(
                code => $code,
                mask => Net::WebSocket::Mask::create(),
            );

            syswrite( $inet, $frame->to_bytes() );

            $SIG{$the_sig} = 'DEFAULT';

            kill $the_sig, $$;
        };
    }

    if ( -t $from_caller ) {
        $_->blocking(0) for ($from_caller, $inet);

        my $s = IO::Select->new( $from_caller, $inet );

        while (1) {
            my ($rdrs_ar, undef, $excs_ar) = IO::Select->select( $s, undef, $s, 10 );

            for my $err (@$excs_ar) {
                $s->remove($err);

                if ($err == $inet) {
                    warn "Error in socket reader!";
                }
                elsif ($err == $from_caller) {
                    warn "Error in input reader!";
                }
                else {
                    die "Improper select() error: [$err]";
                }
            }

            for my $rdr (@$rdrs_ar) {
                if ($rdr == $from_caller) {
                    sysread $from_caller, my $buf, 32768;
                    _chunk_to_remote($buf, $inet);
                }
                elsif ($rdr == $inet) {
                    if ( my $msg = $ept->get_next_message() ) {
                        syswrite( $to_caller, $msg->get_payload() );
                    }
                }
                else {
                    die "Improper reader: [$rdr]";
                }
            }

            if (!$rdrs_ar && !$excs_ar) {
                $ept->check_heartbeat();
                last if $ept->is_closed();
            }
        }
    }
    else {
        while ( sysread $from_caller, my $buf, 32768 ) {
            _chunk_to_remote( $buf, $inet );
        }

        my $close_frame = Net::WebSocket::Frame::close->new(
            code => 'SUCCESS',
            mask => Net::WebSocket::Mask::create(),
        );

        syswrite( $inet, $close_frame->to_bytes() );

        shutdown $inet, Socket::SHUT_WR();

        try {
            while ( my $msg = $ept->get_next_message() ) {
                syswrite( $to_caller, $msg->get_payload() );
            }
        }
        catch {
            my $ok;
            if ( try { $_->isa('Net::WebSocket::X::ReceivedClose') } ) {
                if ( $_->get('frame')->get_payload() eq $close_frame->get_payload() ) {
                    $ok = 1;
                }
            }

            warn $_ if !$ok;
        };

        close $inet;

        close $from_caller;
    }

    return;
}

sub _chunk_to_remote {
    my ($buf, $out_fh) = @_;

    syswrite(
        $out_fh,
        Net::WebSocket::Frame::binary->new(
            payload_sr => \$buf,
            mask => Net::WebSocket::Mask::create(),
        )->to_bytes(),
    );

    return;
}
