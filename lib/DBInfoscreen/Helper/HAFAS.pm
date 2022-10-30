package DBInfoscreen::Helper::HAFAS;

# Copyright (C) 2011-2022 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode encode);
use Travel::Status::DE::HAFAS;
use Mojo::JSON qw(decode_json);
use Mojo::Promise;
use XML::LibXML;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"dbf/${version} on $opt{root_url} +https://finalrewind.org/projects/db-fakedisplay"
	  };

	return bless( \%opt, $class );

}

sub get_json_p {
	my ( $self, $cache, $url ) = @_;

	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		return $promise->resolve($content);
	}

	$self->{log}->debug("get_json_p($url)");

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$self->{log}->warn(
					"hafas->get_json_p($url): HTTP $err->{code} $err->{message}"
				);
				$promise->reject(
					"GET $url returned HTTP $err->{code} $err->{message}");
				return;
			}
			my $body
			  = encode( 'utf-8', decode( 'ISO-8859-15', $tx->res->body ) );

			$body =~ s{^TSLs[.]sls = }{};
			$body =~ s{;$}{};
			$body =~ s{&#x0028;}{(}g;
			$body =~ s{&#x0029;}{)}g;

			my $json = decode_json($body);

			if ( not $json ) {
				$self->{log}->debug("hafas->get_json_p($url): empty response");
				$promise->reject("GET $url returned empty response");
				return;
			}

			$cache->freeze( $url, $json );

			$promise->resolve($json);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->warn("hafas->get_json_p($url): $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

sub get_xml_p {
	my ( $self, $cache, $url ) = @_;

	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		return $promise->resolve($content);
	}

	$self->{log}->debug("get_xml_p($url)");

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$cache->freeze( $url, {} );
				$self->{log}->warn(
					"hafas->get_xml_p($url): HTTP $err->{code} $err->{message}"
				);
				$promise->reject(
					"GET $url returned HTTP $err->{code} $err->{message}");
				return;
			}

			my $body = decode( 'ISO-8859-15', $tx->res->body );

			# <SDay text="... &gt; ..."> is invalid XML, but present
			# regardless. As it is the last tag, we just throw it away.
			$body =~ s{<SDay [^>]*/>}{}s;

			# More fixes for invalid XML
			$body =~ s{P&R}{P&amp;R};
			$body =~ s{& }{&amp; }g;

			# <Attribute [...] text="[...]"[...]"" /> is invalid XML.
			# Work around it.
			$body
			  =~ s{<Attribute([^>]+)text="([^"]*)"([^"=>]*)""}{<Attribute$1text="$2&#042;$3&#042;"}s;

			# Same for <HIMMessage lead="[...]"[...]"[...]" />
			$body
			  =~ s{<HIMMessage([^>]+)lead="([^"]*)"([^"=>]*)"([^"]*)"}{<Attribute$1text="$2&#042;$3&#042;$4"}s;

			# Dito for <HIMMessage [...] lead="[...]<br>[...]">
			# (replace line breaks with space)
			while ( $body
				=~ s{<HIMMessage([^>]+)lead="([^"]*)<br/?>([^"=]*)"}{<HIMMessage$1lead="$2 $3"}gis
			  )
			{
			}

			# ... and <HIMMessage [...] lead="[...]<>[...]">
			# (replace <> with t$t)
			while ( $body
				=~ s{<HIMMessage([^>]+)lead="([^"]*)<>([^"=]*)"}{<HIMMessage$1lead="$2&#11020;$3"}gis
			  )
			{
			}

			# ... and any other HTML tag inside an XML attribute
			# (remove them entirely)
			while ( $body
				=~ s{<HIMMessage([^>]+)lead="([^"]*)<[^>]+>([^"=]*)"}{<HIMMessage$1lead="$2$3"}gis
			  )
			{
			}

			my $tree;

			eval { $tree = XML::LibXML->load_xml( string => $body ) };

			if ($@) {
				$self->{log}->debug("hafas->get_xml_p($url): $@");
				$cache->freeze( $url, {} );
				$promise->reject;
				return;
			}

			my $ret = {
				station  => {},
				stations => [],
				messages => [],
			};

			for my $station ( $tree->findnodes('/Journey/St') ) {
				my $name   = $station->getAttribute('name');
				my $adelay = $station->getAttribute('adelay');
				my $ddelay = $station->getAttribute('ddelay');
				push( @{ $ret->{stations} }, $name );
				$ret->{station}{$name} = {
					adelay => $adelay,
					ddelay => $ddelay,
				};
			}

			for my $message ( $tree->findnodes('/Journey/HIMMessage') ) {
				my $header  = $message->getAttribute('header');
				my $lead    = $message->getAttribute('lead');
				my $display = $message->getAttribute('display');

              # "something is wrong, but we're not telling what" is not helpful.
              # Observed on RRX lines in NRW
				if ( $header
					=~ m{ : \s St..?rung. \s \(Quelle: \s zuginfo.nrw \) $ }x
					and not $lead )
				{
					next;
				}

				push(
					@{ $ret->{messages} },
					{
						header  => $header,
						lead    => $lead,
						display => $display
					}
				);
			}

			$cache->freeze( $url, $ret );
			$promise->resolve($ret);

			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->warn("hafas->get_xml_p($url): $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

sub trainsearch_p {
	my ( $self, %opt ) = @_;

	my $base
	  = 'https://reiseauskunft.bahn.de/bin/trainsearch.exe/dn?L=vs_json&start=yes&rt=1';

	if ( not $opt{date_yy} ) {
		my $now = DateTime->now( time_zone => 'Europe/Berlin' );
		$opt{date_yy}   = $now->strftime('%d.%m.%y');
		$opt{date_yyyy} = $now->strftime('%d.%m.%Y');
	}

	# IRIS reports trains with unknown type as type "-". HAFAS thinks otherwise
	# and prefers the type to be left out entirely in this case.
	$opt{train_req} =~ s{^- }{};

	my $promise = Mojo::Promise->new;

	$self->get_json_p( $self->{realtime_cache},
		"${base}&date=$opt{date_yy}&trainname=$opt{train_req}" )->then(
		sub {
			my ($trainsearch) = @_;

			# Fallback: Take first result
			my $result = $trainsearch->{suggestions}[0];

			# Try finding a result for the current date
			for my $suggestion ( @{ $trainsearch->{suggestions} // [] } ) {

       # Drunken API, sail with care. Both date formats are used interchangeably
				if (
					exists $suggestion->{depDate}
					and (  $suggestion->{depDate} eq $opt{date_yy}
						or $suggestion->{depDate} eq $opt{date_yyyy} )
				  )
				{
            # Train numbers are not unique, e.g. IC 149 refers both to the
            # InterCity service Amsterdam -> Berlin and to the InterCity service
            # Koebenhavns Lufthavn st -> Aarhus.  One workaround is making
            # requests with the stationFilter=80 parameter.  Checking the origin
            # station seems to be the more generic solution, so we do that
            # instead.
					if (    $opt{train_origin}
						and $suggestion->{dep} eq $opt{train_origin} )
					{
						$result = $suggestion;
						last;
					}
				}
			}

			if ($result) {

         # The trip_id's date part doesn't seem to matter -- so far, HAFAS is
         # happy as long as the date part starts with a number. HAFAS-internal
         # tripIDs use this format (withouth leading zero for day of month < 10)
         # though, so let's stick with it.
				my $date_map = $opt{date_yyyy};
				$date_map =~ tr{.}{}d;
				$result->{trip_id} = sprintf( '1|%d|%d|%d|%s',
					$result->{id},   $result->{cycle},
					$result->{pool}, $date_map );
				$promise->resolve($result);
			}
			else {
				$self->{log}->warn(
					"hafas->trainsearch_p($opt{train_req}): train not found");
				$promise->reject("Zug $opt{train_req} nicht gefunden");
			}

           # do not propagate $promise->reject's return value to this promise.
           # Perl implicitly returns the last statement, so we explicitly return
           # nothing to avoid this.
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->warn("hafas->trainsearch_p($opt{train_req}): $err");
			$promise->reject($err);

			# do not propagate $promise->reject's return value to this promise
			return;
		}
	)->wait;

	return $promise;
}

sub get_route_timestamps_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;
	my $now     = DateTime->now( time_zone => 'Europe/Berlin' );

	if ( $opt{train} ) {
		$opt{date_yy}      = $opt{train}->start->strftime('%d.%m.%y');
		$opt{date_yyyy}    = $opt{train}->start->strftime('%d.%m.%Y');
		$opt{train_req}    = $opt{train}->type . ' ' . $opt{train}->train_no;
		$opt{train_origin} = $opt{train}->origin;
	}
	else {
		$opt{train_req} = $opt{train_type} . ' ' . $opt{train_no};
		$opt{date_yy}   = $now->strftime('%d.%m.%y');
		$opt{date_yyyy} = $now->strftime('%d.%m.%Y');
	}

	$self->trainsearch_p(%opt)->then(
		sub {
			my ($trainsearch_result) = @_;
			my $trip_id = $trainsearch_result->{trip_id};
			return Travel::Status::DE::HAFAS->new_p(
				journey => {
					id => $trip_id,

					# name => $opt{train_no},
				},
				cache      => $self->{realtime_cache},
				promise    => 'Mojo::Promise',
				user_agent => $self->{user_agent}->request_timeout(10)
			);
		}
	)->then(
		sub {
			my ($hafas) = @_;
			my $journey = $hafas->result;
			my $ret     = {};

			my $station_is_past = 1;
			for my $stop ( $journey->route ) {
				my $name = $stop->{name};
				$ret->{$name} = {
					sched_arr   => $stop->{sched_arr},
					sched_dep   => $stop->{sched_dep},
					rt_arr      => $stop->{rt_arr},
					rt_dep      => $stop->{rt_dep},
					arr_delay   => $stop->{arr_delay},
					dep_delay   => $stop->{dep_delay},
					load        => $stop->{load},
					isCancelled => (
						( $stop->{arr_cancelled} or not $stop->{sched_arr} )
						  and
						  ( $stop->{dep_cancelled} or not $stop->{sched_dep} )
					),
				};
				if (
					    $station_is_past
					and not $ret->{$name}{isCancelled}
					and $now->epoch < (
						$ret->{$name}{rt_arr} // $ret->{$name}{rt_dep}
						  // $ret->{$name}{sched_arr}
						  // $ret->{$name}{sched_dep} // $now
					)->epoch
				  )
				{
					$station_is_past = 0;
				}
				$ret->{$name}{isPast} = $station_is_past;
			}

			$promise->resolve( $ret, $journey );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

# Input: (HAFAS TripID, line number)
# Output: Promise returning a Travel::Status::DE::HAFAS::Journey instance on success
sub get_polyline_p {
	my ( $self, $trip_id, $line ) = @_;

	my $promise = Mojo::Promise->new;

	Travel::Status::DE::HAFAS->new_p(
		journey => {
			id   => $trip_id,
			name => $line,
		},
		with_polyline => 1,
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $self->{user_agent}->request_timeout(10)
	)->then(
		sub {
			my ($hafas) = @_;
			my $journey = $hafas->result;

			$promise->resolve($journey);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("HAFAS->new_p($trip_id, $line) error: $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

1;
