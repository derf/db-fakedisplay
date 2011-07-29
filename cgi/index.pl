#!/usr/bin/env perl
use Mojolicious::Lite;
use File::ShareDir qw(dist_file);
use HTML::Template;
use Travel::Status::DE::DeutscheBahn;

get '/' => sub {
	my $self    = shift;
	my $station = $self->param('station');
	if ( not $station ) {
		return $self->render;
	}
	$self->redirect_to("/multi/${station}");
} => 'index';

get '/multi/:station' => sub {
	my $self    = shift;
	my $station = $self->stash('station');

	my @params;
	my $status = Travel::Status::DE::DeutscheBahn->new( station => $station );
	my $template = HTML::Template->new(
		filename          => dist_file( 'db-fakedisplay', 'multi-lcd.html' ),
		loop_context_vars => 1,
	);

	for my $result ( $status->results ) {
		push(
			@params,
			{
				time  => $result->time,
				train => $result->train,
				via => [ map { { stop => $_ } } $result->route_interesting(3) ],
				destination => $result->destination,
				platform    => ( split( / /, $result->platform ) )[0],
				info        => $result->info,
			}
		);
	}
	$template->param( departures => \@params );

	$self->render( text => $template->output );
};

app->start();

__DATA__

@@ index.html.ep
% title 'DB Fakedisplay';
<% if (my $error = flash 'error' ) { %>
  Error: <%= $error %><br/>
<% } %>
<%= form_for index => begin %>
  Stop:<br/>
  <%= text_field 'station' %><br/>
  <%= submit_button 'Display' %>
<% end %>
