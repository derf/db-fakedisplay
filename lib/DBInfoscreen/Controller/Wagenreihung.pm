package DBInfoscreen::Controller::Wagenreihung;
# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: BSD-2-Clause

use Mojo::Base 'Mojolicious::Controller';

use Travel::Status::DE::DBWagenreihung;

my $dbf_version = qx{git describe --dirty} || 'experimental';

chomp $dbf_version;

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

			$self->render(
				'wagenreihung',
				wr_error => undef,
				title    => join( ' / ',
					map { $wr->train_type . ' ' . $_ } $wr->train_numbers ),
				train_no  => $train,
				wr        => $wr,
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
				hide_opts => 1,
			);
		}
	)->wait;

}

1;
