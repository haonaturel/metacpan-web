package MetaCPAN::Web::Test;

# ABSTRACT: Test class for MetaCPAN::Web

use strict;
use warnings;
use Plack::Test;
use HTTP::Request::Common;
use HTTP::Message::PSGI;
use HTML::Tree;
use Test::More;
use Test::XPath;
use Try::Tiny;
use Encode;
use base 'Exporter';
our @EXPORT = qw(
    GET
    test_psgi
    override_api_response
    app
    tx
    test_cache_headers
);

# TODO: use Sub:Override?
# save a copy in case we override
my $orig_request = \&AnyEvent::Curl::Multi::request;

sub override_api_response {
    require MetaCPAN::Web::Model::API;

    my $responder = pop;
    my $matches   = {@_};

    no warnings 'redefine';
    *AnyEvent::Curl::Multi::request = sub {
        if ( ( $matches->{if} ? $matches->{if}->(@_) : 1 )
            and my $res = $responder->(@_) )
        {
            $res = HTTP::Response->from_psgi($res) if ref $res eq 'ARRAY';

          # return an object with a ->cv that's ready so that the cb will fire
            my $ret = bless { cv => AE::cv() },
                'AnyEvent::Curl::Multi::Handle';
            $ret->cv->send( $res, {} );
            return $ret;
        }
        else {
            goto &$orig_request;
        }
    };
    return;
}

sub app { require 'app.psgi'; }    ## no critic (Require)

sub tx {
    my ( $res, $opts ) = @_;
    my $xml = $res->content;
    $opts ||= {};

    # Determine type of xml document.
    if ( delete $opts->{feed} ) {
        ( $opts->{xmlns} ||= {} )->{rdf} = 'http://purl.org/rss/1.0/';
    }

    # Default to html (disable with `html => 0`).
    elsif ( !exists $opts->{html} ) {
        $opts->{html} = 1;
    }

# Text::XPath has `is_html` but the LibXML HTML parser doesn't like some html 5 (like nav).
    if ( delete $opts->{html} ) {
        $xml = HTML::TreeBuilder->new_from_content( $res->content )->as_XML;
    }

    # A nice alternative to XPath when the full power isn't needed.
    if ( delete $opts->{css} ) {
        $opts->{filter} = 'css_selector';
    }

    # Upgrading some library (not sure which) in Sep/Oct 2013 started
    # returning $xml with wide characters (which cases decode to croak).
    try { $xml = decode_utf8($xml) if !Encode::is_utf8($xml); }
    catch { warn $_[0] };

    my $tx = Test::XPath->new( xml => $xml, %$opts );

  # https://metacpan.org/module/DWHEELER/Test-XPath-0.16/lib/Test/XPath.pm#xpc
    $tx->xpc->registerFunction(
        grep => sub {
            my ( $nodelist, $regex ) = @_;
            my $result = XML::LibXML::NodeList->new;
            for my $node ( $nodelist->get_nodelist ) {
                $result->push($node) if $node->textContent =~ $regex;
            }
            return $result;
        }
    );
    return $tx;
}

sub test_cache_headers {
    my ( $res, $conf ) = @_;

    is(
        $res->header('Cache-Control'),
        $conf->{cache_control},
        "Cache Header: Cache-Control ok"
    ) if $conf->{cache_control};

    is(
        $res->header('Surrogate-Key'),
        $conf->{surrogate_key},
        "Cache Header: Surrogate-Key ok"
    ) if $conf->{surrogate_key};

    is(
        $res->header('Surrogate-Control'),
        $conf->{surrogate_control},
        "Cache Header: Surrogate-Control ok"
    ) if $conf->{surrogate_control};
}

1;

=head1 ENVIRONMENTAL VARIABLES

Sets C<PLACK_TEST_IMPL> to C<Server> and C<PLACK_SERVER> to C<Twiggy>.

=head1 EXPORTS

=head2 GET

L<HTTP::Request::Common/GET>

=head2 test_psgi

L<Plack::Test/test_psgi>

=head2 override_api_response

Define a sub to intercept api requests and return your own response.
Response can be L<HTTP::Response> or a PSGI array ref.

    override_api_response(sub { return [ 200, ["Content-Type" => "text/plain"], ["body"] ]; });

Conditionally with another sub:

    override_api_response(
      if => sub { return $_[1] =~ /foo/ },
      sub { return HTTP::Response->new(200, "OK", ["Content-type" => "text/plain"], "body"); }
    );

=head2 app

Returns the L<MetaCPAN::Web> psgi app.

=head2 tx($res)

Parses C<< $res->content >> and generates a L<Test::XPath> object.

=head2 test_cache_headers

  test_cache_headers(
      $res,
      {
          cache_control     => 'max-age=3600',
          surrogate_key     => 'SOURCE',
          surrogate_control => 'max-age=31556952',
      }
  );

Checks headers on a response, only checks provieded keys

=cut
