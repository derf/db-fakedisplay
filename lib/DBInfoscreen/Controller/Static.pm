package DBInfoscreen::Controller::Static;

# Copyright (C) 2011-2020 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Controller';

my %default = (
	mode   => 'app',
	admode => 'deparr',
);

sub geostop {
	my ($self) = @_;

	$self->render(
		'geostop',
		with_geostop => 1,
		hide_opts    => 1,
		hide_footer  => 1,
	);
}

sub about {
	my ($self) = @_;

	$self->render(
		'about',
		hide_opts => 1,
		hide_footer => 1,
	);
}

sub privacy {
	my ($self) = @_;

	$self->render( 'privacy', hide_opts => 1, hide_footer => 1 );
}

sub imprint {
	my ($self) = @_;

	$self->render( 'imprint', hide_opts => 1, hide_footer => 1 );
}

1;
