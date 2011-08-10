#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
use File::ShareDir qw(dist_file);
use HTML::Template;
use Travel::Status::DE::DeutscheBahn;

sub get_results_for {
	my ($station) = @_;

	my $cache = Cache::File->new(
		cache_root => '/tmp/db-fake',
		default_expires => '900 sec'
	);

	my $results = $cache->thaw($station);

	if (not $results) {
		my $status = Travel::Status::DE::DeutscheBahn->new( station => $station
		);
		$results = [$status->results];
		$cache->freeze($station, $results);
	}

	return @{ $results };
}

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
	my $template = HTML::Template->new(
		filename          => dist_file( 'db-fakedisplay', 'multi-lcd.html' ),
		loop_context_vars => 1,
	);

	for my $result ( get_results_for($station) ) {
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
