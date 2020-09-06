package DBInfoscreen::Helper::HAFAS;

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode encode);
use Mojo::JSON qw(decode_json);
use XML::LibXML;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
		  "dbf/${version} +https://finalrewind.org/projects/db-fakedisplay" };

	return bless( \%opt, $class );

}

sub hafas_rest_req {
	my ( $self, $cache, $url ) = @_;

	if ( my $content = $cache->thaw($url) ) {
		return $content;
	}

	my $res = eval { $self->{user_agent}->get($url)->result; };

	if ($@) {
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

	my $res = eval { $self->{user_agent}->get($url)->result };

	if ($@) {
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

	my $res = eval { $self->{user_agent}->get($url)->result };

	if ($@) {
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

sub get_route_timestamps {
	my ( $self, %opt ) = @_;

	my $base
	  = 'https://reiseauskunft.bahn.de/bin/trainsearch.exe/dn?L=vs_json&start=yes&rt=1';
	my ( $date_yy, $date_yyyy, $train_no, $train_origin );

	if ( $opt{train} ) {
		$date_yy      = $opt{train}->start->strftime('%d.%m.%y');
		$date_yyyy    = $opt{train}->start->strftime('%d.%m.%Y');
		$train_no     = $opt{train}->type . ' ' . $opt{train}->train_no;
		$train_origin = $opt{train}->origin;
	}
	else {
		my $now = DateTime->now( time_zone => 'Europe/Berlin' );
		$date_yy   = $now->strftime('%d.%m.%y');
		$date_yyyy = $now->strftime('%d.%m.%Y');
		$train_no  = $opt{train_no};
	}

	my $trainsearch = $self->hafas_json_req( $self->{main_cache},
		"${base}&date=${date_yy}&trainname=${train_no}" );

	if ( not $trainsearch ) {
		return;
	}

	# Fallback: Take first result
	my $trainlink = $trainsearch->{suggestions}[0]{trainLink};

	# Try finding a result for the current date
	for my $suggestion ( @{ $trainsearch->{suggestions} // [] } ) {

       # Drunken API, sail with care. Both date formats are used interchangeably
		if (
			exists $suggestion->{depDate}
			and (  $suggestion->{depDate} eq $date_yy
				or $suggestion->{depDate} eq $date_yyyy )
		  )
		{
			# Train numbers are not unique, e.g. IC 149 refers both to the
			# InterCity service Amsterdam -> Berlin and to the InterCity service
			# Koebenhavns Lufthavn st -> Aarhus.  One workaround is making
			# requests with the stationFilter=80 parameter.  Checking the origin
			# station seems to be the more generic solution, so we do that
			# instead.
			if ( $train_origin and $suggestion->{dep} eq $train_origin ) {
				$trainlink = $suggestion->{trainLink};
				last;
			}
		}
	}

	if ( not $trainlink ) {
		return;
	}

	$base = 'https://reiseauskunft.bahn.de/bin/traininfo.exe/dn';

	my $traininfo = $self->hafas_json_req( $self->{realtime_cache},
		"${base}/${trainlink}?rt=1&date=${date_yy}&L=vs_json" );

	if ( not $traininfo or $traininfo->{error} ) {
		return;
	}

	my $traindelay = $self->hafas_xml_req( $self->{realtime_cache},
		"${base}/${trainlink}?rt=1&date=${date_yy}&L=vs_java3" );

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

1;
