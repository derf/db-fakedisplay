package DBInfoscreen::Helper::HAFAS;

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode encode);
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

			# <SDay text="... &gt; ..."> is invalid HTML, but present
			# regardless. As it is the last tag, we just throw it away.
			$body =~ s{<SDay [^>]*/>}{}s;

			my $tree;

			eval { $tree = XML::LibXML->load_xml( string => $body ) };

			if ($@) {
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
			$self->{log}->warn("hafas->get_json_p($url): $err");
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

	my $promise = Mojo::Promise->new;

	$self->get_json_p( $self->{realtime_cache},
		"${base}&date=$opt{date_yy}&trainname=$opt{train_no}" )->then(
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
				$promise->reject("Zug $opt{train_no} nicht gefunden");
			}

           # do not propagate $promise->reject's return value to this promise.
           # Perl implicitly returns the last statement, so we explicitly return
           # nothing to avoid this.
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
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

	if ( $opt{train} ) {
		$opt{date_yy}      = $opt{train}->start->strftime('%d.%m.%y');
		$opt{date_yyyy}    = $opt{train}->start->strftime('%d.%m.%Y');
		$opt{train_no}     = $opt{train}->type . ' ' . $opt{train}->train_no;
		$opt{train_origin} = $opt{train}->origin;
	}
	else {
		my $now = DateTime->now( time_zone => 'Europe/Berlin' );
		$opt{date_yy}   = $now->strftime('%d.%m.%y');
		$opt{date_yyyy} = $now->strftime('%d.%m.%Y');
	}

	my $base = 'https://reiseauskunft.bahn.de/bin/traininfo.exe/dn';
	my ( $trainsearch_result, $trainlink );

	$self->trainsearch_p(%opt)->then(
		sub {
			($trainsearch_result) = @_;
			$trainlink = $trainsearch_result->{trainLink};
			return Mojo::Promise->all(
				$self->get_json_p(
					$self->{realtime_cache},
					"${base}/${trainlink}?rt=1&date=$opt{date_yy}&L=vs_json"
				),
				$self->get_xml_p(
					$self->{realtime_cache},
					"${base}/${trainlink}?rt=1&date=$opt{date_yy}&L=vs_java3"
				)
			);
		}
	)->then(
		sub {
			my ( $traininfo, $traindelay ) = @_;
			$traininfo  = $traininfo->[0];
			$traindelay = $traindelay->[0];
			if ( not $traininfo or $traininfo->{error} ) {
				$promise->reject;
				return;
			}
			my $ret = {};

			my $strp = DateTime::Format::Strptime->new(
				pattern   => '%d.%m.%y %H:%M',
				time_zone => 'Europe/Berlin',
			);

			for
			  my $station ( @{ $traininfo->{suggestions}[0]{locations} // [] } )
			{
				my $name = $station->{name};
				my $arr  = $station->{arrDate} . ' ' . $station->{arrTime};
				my $dep  = $station->{depDate} . ' ' . $station->{depTime};
				$ret->{$name} = {
					sched_arr => scalar $strp->parse_datetime($arr),
					sched_dep => scalar $strp->parse_datetime($dep),
				};
				if ( exists $traindelay->{station}{$name} ) {
					my $delay = $traindelay->{station}{$name};
					if (    $ret->{$name}{sched_arr}
						and $delay->{adelay}
						and $delay->{adelay} =~ m{^\d+$} )
					{
						$ret->{$name}{rt_arr} = $ret->{$name}{sched_arr}
						  ->clone->add( minutes => $delay->{adelay} );
					}
					if (    $ret->{$name}{sched_dep}
						and $delay->{ddelay}
						and $delay->{ddelay} =~ m{^\d+$} )
					{
						$ret->{$name}{rt_dep} = $ret->{$name}{sched_dep}
						  ->clone->add( minutes => $delay->{ddelay} );
					}
				}
			}

			$promise->resolve( $ret, $traindelay // {}, $trainsearch_result );
			return;
		}
	)->catch(
		sub {
			$promise->reject;
			return;
		}
	)->wait;

	return $promise;
}

# Input: (HAFAS TripID, line number)
# Output: Promise returning a
# https://github.com/public-transport/hafas-client/blob/4/docs/trip.md instance
# on success
sub get_polyline_p {
	my ( $self, $trip_id, $line ) = @_;

	my $url
	  = "https://2.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true";
	my $cache   = $self->{realtime_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		$self->{log}->debug("GET $url (cached)");
		return $promise;
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;
			$self->{log}->debug("GET $url (OK)");
			my $json = decode_json( $tx->res->body );
			my @coordinate_list;

			for my $feature ( @{ $json->{polyline}{features} } ) {
				if ( exists $feature->{geometry}{coordinates} ) {
					push( @coordinate_list, $feature->{geometry}{coordinates} );
				}

				#if ($feature->{type} eq 'Feature') {
				#	say "Feature " . $feature->{properties}{name};
				#}
			}

			my $ret = {
				name     => $json->{line}{name} // '?',
				polyline => [@coordinate_list],
				raw      => $json,
			};

			$cache->freeze( $url, $ret );
			$promise->resolve($ret);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("GET $url (error: $err)");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

1;
