package DBInfoscreen::Controller::Static;

# Copyright (C) 2011-2020 Birte Kristina Friesel
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

sub geostop {
	my ($self) = @_;

	my ( $api_link, $api_text, $api_icon );
	if ( $self->param('hafas') ) {
		$api_link = '/_autostop';
		$api_text = 'Auf Bahnverkehr wechseln';
		$api_icon = 'directions_bus';
	}
	else {
		$api_link = '/_autostop?hafas=1';
		$api_text = 'Auf Nahverkehr wechseln';
		$api_icon = 'train';
	}

	$self->render(
		'geostop',
		api_link     => $api_link,
		api_text     => $api_text,
		api_icon     => $api_icon,
		with_geostop => 1,
		hide_opts    => 1
	);
}

sub about {
	my ($self) = @_;

	$self->render(
		'about',
		hide_opts => 1,
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
