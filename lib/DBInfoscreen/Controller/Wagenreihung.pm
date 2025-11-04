package DBInfoscreen::Controller::Wagenreihung;

# Copyright (C) 2011-2020 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw(b64_encode b64_decode);

use utf8;

use DateTime;
use Travel::Status::DE::DBRIS::Formation;

sub handle_wagenreihung_error {
	my ( $self, $train, $err ) = @_;

	$self->render(
		'wagenreihung',
		title     => $train,
		wr_error  => $err,
		wr        => undef,
		wref      => undef,
		hide_opts => 1,
		status    => 500,
	);
}

sub wagenreihung {
	my ($self) = @_;
	my $exit_side = $self->param('e');

	my $train_type = $self->param('tt');
	my $train_no   = $self->param('tn');
	my $eva        = $self->param('eva');
	my $dt         = DateTime->from_epoch(
		epoch     => $self->param('dt'),
		time_zone => 'UTC'
	);

	my $train = "${train_type} ${train_no}";

	$self->render_later;

	$self->dbris->get_wagonorder_p(
		train_type => $train_type,
		train_no   => $train_no,
		datetime   => $dt,
		eva        => $eva,
	)->then(
		sub {
			my ($status) = @_;
			my $wr = $status->result;

			if ( $exit_side and $exit_side =~ m{^a} ) {
				if ( $wr->sectors and defined $wr->direction ) {
					my $section_0 = ( $wr->sectors )[0];
					my $direction = $wr->direction;
					if ( $section_0->name eq 'A' and $direction == 0 ) {
						$exit_side =~ s{^a}{};
					}
					elsif ( $section_0->name ne 'A' and $direction == 100 ) {
						$exit_side =~ s{^a}{};
					}
					else {
						$exit_side = ( $exit_side eq 'ar' ) ? 'l' : 'r';
					}
				}
				else {
					$exit_side = undef;
				}
			}

			my $wref = {
				e  => $exit_side ? substr( $exit_side, 0, 1 ) : '',
				tt => $wr->train_type,
				tn => $train_no,
				p  => $wr->platform
			};

			#if ( $wr->has_bad_wagons ) {

			#	# create fake positions as the correct ones are not available
			#	my $pos = 0;
			#	for my $wagon ( $wr->wagons ) {
			#		$wagon->{position}{start_percent} = $pos;
			#		$wagon->{position}{end_percent}   = $pos + 4;
			#		$pos += 4;
			#	}
			#}
			if ( defined $wr->direction and scalar $wr->carriages > 2 ) {

				# wagenlexikon images only know one orientation. They assume
				# that the second class (i.e., the wagon with the lowest
				# wagon number) is in the leftmost carriage(s). We define the
				# wagon with the lowest start_percent value to be leftmost
				# and invert the direction passed on to $wref if it is not
				# the wagon with the lowest wagon number.

				# Note that we need to check both the first two and the last two
				# wagons as the train may consist of several wings. If their
				# order differs, we do not show a direction, as we do not
				# handle that case yet.

				my @wagons = $wr->carriages;

				# skip first/last wagon as it may be a locomotive
				my $wna1 = $wagons[1]->number;
				my $wna2 = $wagons[2]->number;
				my $wnb1 = $wagons[-3]->number;
				my $wnb2 = $wagons[-2]->number;
				my $wpa1 = $wagons[1]->start_percent;
				my $wpa2 = $wagons[2]->start_percent;
				my $wpb1 = $wagons[-3]->start_percent;
				my $wpb2 = $wagons[-2]->start_percent;

				if (    $wna1 =~ m{^\d+$}
					and $wna2 =~ m{^\d+$}
					and $wnb1 =~ m{^\d+$}
					and $wnb2 =~ m{^\d+$} )
				{

					# We need to perform normalization in two cases:
					# * wagon 1 is leftmost and its number is higher than wagon 2
					# * wagon 1 is rightmost and its number is lower than wagon 2
					#   (-> the leftmost wagon has the highest number)

					# However, if wpa/wna und wpb/wnb do not match, we have a
					# winged train with different normalization requirements
					# in its wings. We do not handle that case yet.
					if ( ( $wna1 <=> $wna2 ) != ( $wnb1 <=> $wnb2 ) ) {

						# unhandled. Do not set $wref->{d}.
					}
					elsif (( $wpa1 < $wpa2 and $wna1 > $wna2 )
						or ( $wpa1 > $wpa2 and $wna1 < $wna2 ) )
					{
						# perform normalization
						$wref->{d} = 100 - $wr->direction;
					}
					else {
						# no normalization required
						$wref->{d} = $wr->direction;
					}
				}
			}

			my $exit_dir = 'unknown';
			if ( defined $wr->direction and $exit_side ) {
				if ( $wr->direction == 0 and $exit_side eq 'l' ) {
					$exit_dir = 'left';
				}
				elsif ( $wr->direction == 0 and $exit_side eq 'r' ) {
					$exit_dir = 'right';
				}
				elsif ( $wr->direction == 100 and $exit_side eq 'l' ) {
					$exit_dir = 'right';
				}
				elsif ( $wr->direction == 100 and $exit_side eq 'r' ) {
					$exit_dir = 'left';
				}
			}

			$wref = b64_encode( encode_json($wref) );

			my $title = join( ' / ', map { $_->{name} } $wr->trains );

			$self->render(
				'wagenreihung',
				description => sprintf( 'Ist-Wagenreihung %s', $title ),
				wr_error    => undef,
				title       => $title,
				wr          => $wr,
				wref        => $wref,
				exit_dir    => $exit_dir,
				hide_opts   => 1,

				#ts          => $json->{ts},
			);
		}
	)->catch(
		sub {
			my ($err) = @_;

			$self->handle_wagenreihung_error( $train,
				$err // "Unbekannter Fehler" );
			return;
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

	my @wagon_files
	  = ("https://lib.finalrewind.org/dbdb/db_wagen/${wagon_id}.png");

	if ( $self->app->dbdb_wagon->{"${wagon_id}_u"} ) {
		@wagon_files = (
			"https://lib.finalrewind.org/dbdb/db_wagen/${wagon_id}_u.png",
			"https://lib.finalrewind.org/dbdb/db_wagen/${wagon_id}_l.png"
		);
	}

	my $title = 'Wagen ' . $wagon_id;

	if ( $wref->{tt} and $wref->{tn} ) {
		$title = sprintf( '%s %s', $wref->{tt}, $wref->{tn} );
		if ($wagon_no) {
			$title .= ' Wagen ' . $wagon_no;
		}
		else {
			$title .= ' Wagen ' . $wagon_id;
		}
	}

	if ( defined $wref->{d} and $wref->{e} ) {
		if ( $wref->{d} == 0 and $wref->{e} eq 'l' ) {
			$wref->{e} = 'd';
		}
		elsif ( $wref->{d} == 0 and $wref->{e} eq 'r' ) {
			$wref->{e} = 'u';
		}
		elsif ( $wref->{d} == 100 and $wref->{e} eq 'l' ) {
			$wref->{e} = 'u';
		}
		elsif ( $wref->{d} == 100 and $wref->{e} eq 'r' ) {
			$wref->{e} = 'd';
		}
	}
	else {
		$wref->{e} = '';
	}

	$self->render(
		'wagen',
		description => ( $wref->{s} ? 'Position von ' : q{} )
		  . $title
		  . ( $wref->{s} ? " in $wref->{s}" : q{} ),
		title       => $title,
		wagon_files => [@wagon_files],
		wagon_data  => $self->app->dbdb_wagon->{$wagon_id},
		wref        => $wref,
		hide_opts   => 1,
	);
}

1;
