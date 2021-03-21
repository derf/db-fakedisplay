package DBInfoscreen::Controller::Static;

# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Controller';

my %default = (
	mode   => 'app',
	admode => 'deparr',
);

sub redirect {
	my ($self) = @_;
	my $input  = $self->param('input');
	my $params = $self->req->params;

	$params->remove('input');

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

	if ( $input =~ m{ ^ [a-zA-Z]{1,5} \s+ \d+ $ }x ) {
		$self->redirect_to("/z/${input}?${params}");
	}
	else {
		$self->redirect_to("/${input}?${params}");
	}
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
