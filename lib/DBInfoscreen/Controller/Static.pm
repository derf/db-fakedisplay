package DBInfoscreen::Controller::Static;
# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: BSD-2-Clause

use Mojo::Base 'Mojolicious::Controller';

my %default = (
	mode   => 'app',
	admode => 'deparr',
);

sub redirect {
	my ($self)  = @_;
	my $station = $self->param('station');
	my $params  = $self->req->params;

	$params->remove('station');

	for my $param (qw(platforms mode admode via)) {
		if (
			not $params->param($param)
			or ( exists $default{$param}
				and $params->param($param) eq $default{$param} )
		  )
		{
			$params->remove($param);
		}
	}

	$params = $params->to_string;

	$self->redirect_to("/${station}?${params}");
}

sub geolocation {
	my ($self) = @_;

	$self->render(
		'geolocation',
		with_geolocation => 1,
		hide_opts        => 1
	);
}

sub about {
	my ($self) = @_;

	$self->render(
		'about',
		hide_opts => 1,
		version   => $self->config->{version}
	);
}

sub privacy {
	my ($self) = @_;

	$self->render( 'privacy', hide_opts => 1 );
}

sub imprint {
	my ($self) = @_;

	$self->render( 'imprint', hide_opts => 1 );
}

1;
