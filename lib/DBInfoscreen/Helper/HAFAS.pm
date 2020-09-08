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

sub hafas_rest_req {
	my ( $self, $cache, $url ) = @_;

	if ( my $content = $cache->thaw($url) ) {
		return $content;
	}

	my $res
	  = eval { $self->{user_agent}->get( $url => $self->{header} )->result; };

	if ($@) {
		$self->{log}->debug("hafas_rest_req($url): $@");
		return;
	}
	if ( $res->is_error ) {
		return;
	}

	my $json = decode_json( $res->body );

	$cache->freeze( $url, $json );

	return $json;
}

sub hafas_json_req {
	my ( $self, $cache, $url ) = @_;

	if ( my $content = $cache->thaw($url) ) {
		return $content;
	}

	my $res
	  = eval { $self->{user_agent}->get( $url => $self->{header} )->result };

	if ($@) {
		$self->{log}->debug("hafas_json_req($url): $@");
		return;
	}
	if ( $res->is_error ) {
		return;
	}

	my $body = encode( 'utf-8', decode( 'ISO-8859-15', $res->body ) );

	$body =~ s{^TSLs[.]sls = }{};
	$body =~ s{;$}{};
	$body =~ s{&#x0028;}{(}g;
	$body =~ s{&#x0029;}{)}g;

	my $json = decode_json($body);

	$cache->freeze( $url, $json );

	return $json;
}

sub hafas_xml_req {
	my ( $self, $cache, $url ) = @_;

	if ( my $content = $cache->thaw($url) ) {
		return $content;
	}

	my $res
	  = eval { $self->{user_agent}->get( $url => $self->{header} )->result };

	if ($@) {
		$self->{log}->debug("hafas_xml_req($url): $@");
		return;
	}
	if ( $res->is_error ) {
		$cache->freeze( $url, {} );
		return;
	}

	my $body = decode( 'ISO-8859-15', $res->body );

	# <SDay text="... &gt; ..."> is invalid HTML, but present
	# regardless. As it is the last tag, we just throw it away.
	$body =~ s{<SDay [^>]*/>}{}s;

	my $tree;

	eval { $tree = XML::LibXML->load_xml( string => $body ) };

	if ($@) {
		$cache->freeze( $url, {} );
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

	return $ret;
}

sub trainsearch {
	my ( $self, %opt ) = @_;

	my $base
	  = 'https://reiseauskunft.bahn.de/bin/trainsearch.exe/dn?L=vs_json&start=yes&rt=1';

	if ( not $opt{date_yy} ) {
		my $now = DateTime->now( time_zone => 'Europe/Berlin' );
		$opt{date_yy}   = $now->strftime('%d.%m.%y');
		$opt{date_yyyy} = $now->strftime('%d.%m.%Y');
	}

	my $trainsearch = $self->hafas_json_req( $self->{realtime_cache},
		"${base}&date=$opt{date_yy}&trainname=$opt{train_no}" );

	if ( not $trainsearch ) {
		return;
	}

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
			$result->{id}, $result->{cycle}, $result->{pool}, $date_map );
	}

	return $result;
}

sub get_route_timestamps {
	my ( $self, %opt ) = @_;

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

	my $trainsearch_result = $self->trainsearch(%opt);

	if ( not $trainsearch_result ) {
		return;
	}

	my $trainlink = $trainsearch_result->{trainLink};

	my $base = 'https://reiseauskunft.bahn.de/bin/traininfo.exe/dn';

	my $traininfo = $self->hafas_json_req( $self->{realtime_cache},
		"${base}/${trainlink}?rt=1&date=$opt{date_yy}&L=vs_json" );

	if ( not $traininfo or $traininfo->{error} ) {
		return;
	}

	my $traindelay = $self->hafas_xml_req( $self->{realtime_cache},
		"${base}/${trainlink}?rt=1&date=$opt{date_yy}&L=vs_java3" );

	my $ret = {};

	my $strp = DateTime::Format::Strptime->new(
		pattern   => '%d.%m.%y %H:%M',
		time_zone => 'Europe/Berlin',
	);

	for my $station ( @{ $traininfo->{suggestions}[0]{locations} // [] } ) {
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

	return ( $ret, $traindelay // {} );
}

sub get_tripid {
	my ( $self, $train ) = @_;

	my $cache = $self->{main_cache};
	my $eva   = $train->station_uic;

	my $dep_ts = DateTime->now( time_zone => 'Europe/Berlin' );
	my $url
	  = "https://2.db.transport.rest/stations/${eva}/departures?duration=5&when=$dep_ts";

	if ( $train->sched_departure ) {
		$dep_ts = $train->sched_departure->epoch;
		$url
		  = "https://2.db.transport.rest/stations/${eva}/departures?duration=5&when=$dep_ts";
	}
	elsif ( $train->sched_arrival ) {
		$dep_ts = $train->sched_arrival->epoch;
		$url
		  = "https://2.db.transport.rest/stations/${eva}/arrivals?duration=5&when=$dep_ts";
	}

	my $json = $self->hafas_rest_req( $cache, $url );

	#say "looking for " . $train->train_no . " in $url";
	for my $result ( @{ $json // [] } ) {
		my $trip_id = $result->{tripId};
		my $fahrt   = $result->{line}{fahrtNr};

		#say "checking $fahrt";
		if ( $result->{line} and $result->{line}{fahrtNr} == $train->train_no )
		{
			#say "Trip ID is $trip_id";
			return $trip_id;
		}
		else {
			#say "unmatched Trip ID $trip_id";
		}
	}
	return;
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
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("GET $url (error: $err)");
			$promise->reject($err);
		}
	)->wait;

	return $promise;
}

1;
