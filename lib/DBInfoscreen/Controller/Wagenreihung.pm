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
		departure    => $departure,
		train_number => $train,
	);

	$self->render(
		'wagenreihung',
		wr        => $wr,
		hide_opts => 1,
	);
}

1;
