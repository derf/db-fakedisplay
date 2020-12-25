package DBInfoscreen::Controller::Wagenreihung;

# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: BSD-2-Clause

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw(b64_encode b64_decode);

use utf8;

use Travel::Status::DE::DBWagenreihung;
use Travel::Status::DE::DBWagenreihung::Wagon;

sub zugbildung_db {
	my ($self) = @_;

	my $train_no = $self->param('train');

	my $details = $self->app->train_details_db->{$train_no};

	if ( not $details ) {
		$self->render( 'not_found',
			message => "Keine Daten zu Zug ${train_no} bekannt" );
		return;
	}

	my @wagons;

	for my $wagon ( @{ $details->{wagons} } ) {
		my $wagon_type   = $wagon->{type};
		my $wagon_number = $wagon->{number};
		my %wagon        = (
			fahrzeugnummer      => "",
			fahrzeugtyp         => $wagon_type,
			kategorie           => $wagon_type =~ m{^[0-9.]+$} ? 'LOK' : '',
			train_no            => $train_no,
			wagenordnungsnummer => $wagon_number,
			positionamhalt      => {
				startprozent => 0,
				endeprozent  => 0,
				startmeter   => 0,
				endemeter    => 0,
			}
		);
		my $wagon = Travel::Status::DE::DBWagenreihung::Wagon->new(%wagon);

		if ( $details->{type} ) {
			$wagon->set_traintype( $details->{type} );
		}
		push( @wagons, $wagon );
	}

	my $pos = 0;
	for my $wagon (@wagons) {
		$wagon->{position}{start_percent} = $pos;
		$wagon->{position}{end_percent}   = $pos + 5;
		$pos += 5;
	}

	my $train_type = $details->{rawType};
	$train_type =~ s{ - .* }{}x;

	my $route_start = $details->{route}{start} // $details->{route}{preStart};
	my $route_end   = $details->{route}{end}   // $details->{route}{postEnd};
	my $route       = "${route_start} → ${route_end}";

	$self->render(
		'zugbildung_db',
		wr_error  => undef,
		title     => $train_type . ' ' . $train_no,
		route     => $route,
		zb        => $details,
		train_no  => $train_no,
		wagons    => [@wagons],
		hide_opts => 1,
	);
}

sub wagenreihung {
	my ($self)    = @_;
	my $train     = $self->stash('train');
	my $departure = $self->stash('departure');

	$self->render_later;

	$self->wagonorder->get_p( $train, $departure )->then(
		sub {
			my ($json) = @_;
			my $wr;
			eval {
				$wr
				  = Travel::Status::DE::DBWagenreihung->new(
					from_json => $json );
			};
			if ($@) {
				$self->render(
					'wagenreihung',
					title     => "Zug $train",
					wr_error  => scalar $@,
					train_no  => $train,
					wr        => undef,
					wref      => undef,
					hide_opts => 1,
				);
			}

			if ( $wr->has_bad_wagons ) {

				# create fake positions as the correct ones are not available
				my $pos = 0;
				for my $wagon ( $wr->wagons ) {
					$wagon->{position}{start_percent} = $pos;
					$wagon->{position}{end_percent}   = $pos + 4;
					$pos += 4;
				}
			}

			my $wref = {
				d  => $wr->direction,
				tt => $wr->train_type,
				tn => $train,
				s  => $wr->station_name,
				p  => $wr->platform
			};
			$wref = b64_encode( encode_json($wref) );

			$self->render(
				'wagenreihung',
				wr_error => undef,
				title    => join( ' / ',
					map { $wr->train_type . ' ' . $_ } $wr->train_numbers ),
				train_no  => $train,
				wr        => $wr,
				wref      => $wref,
				hide_opts => 1,
			);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->render(
				'wagenreihung',
				title     => "Zug $train",
				wr_error  => scalar $err,
				train_no  => $train,
				wr        => undef,
				wref      => undef,
				hide_opts => 1,
			);
		}
	)->wait;

}

sub wagen {
	my ($self)   = @_;
	my $wagon_id = $self->stash('wagon');
	my $wagon_no = $self->param('n');
	my $section  = $self->param('s');
	my $wref     = $self->param('r');

	if ( not $self->app->dbdb_wagon->{$wagon_id} ) {
		$self->render(
			'not_found',
			message   => "Keine Daten zu Wagentyp \"${wagon_id}\" vorhanden",
			hide_opts => 1
		);
		return;
	}

	eval { $wref = decode_json( b64_decode($wref) ); };
	if ($@) {
		$wref = {};
	}

	$wref->{wn} = $wagon_no;
	$wref->{ws} = $section;

	my $wagon_file
	  = "https://lib.finalrewind.org/dbdb/db_wagen/${wagon_id}.png";

	my $title = "Wagen $wagon_id";

	if ( $wref->{tt} and $wref->{tn} ) {
		$title = sprintf( '%s %s', $wref->{tt}, $wref->{tn} );
		if ($wagon_no) {
			$title .= " Wagen $wagon_no";
		}
		else {
			$title .= " Wagen $wagon_id";
		}
	}

	$self->render(
		'wagen',
		title      => $title,
		wagon_file => $wagon_file,
		wref       => $wref,
		hide_opts  => 1,
	);
}

1;
