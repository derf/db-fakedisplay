package DBInfoscreen::Controller::Wagenreihung;
use Mojo::Base 'Mojolicious::Controller';

# Copyright (C) 2011-2019 Daniel Friesel <derf+dbf@finalrewind.org>
# License: 2-Clause BSD

use Travel::Status::DE::DBWagenreihung;

sub wagenreihung {
	my ($self)    = @_;
	my $train     = $self->stash('train');
	my $departure = $self->stash('departure');

	my $wr = Travel::Status::DE::DBWagenreihung->new(
		cache        => $self->app->cache_iris_rt,
		departure    => $departure,
		train_number => $train,
	);

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
		title =>
		  join( ' / ', map { $wr->train_type . ' ' . $_ } $wr->train_numbers ),
		wr        => $wr,
		hide_opts => 1,
	);
}

1;
