#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
use File::ShareDir qw(dist_file);
use HTML::Template;
use Travel::Status::DE::DeutscheBahn;

our $VERSION = '0.00';

sub get_results_for {
	my ($station) = @_;

	my $cache = Cache::File->new(
		cache_root      => '/tmp/db-fake',
		default_expires => '900 sec'
	);

	my $results = $cache->thaw($station);

	if ( not $results ) {
		my $status
		  = Travel::Status::DE::DeutscheBahn->new( station => $station );
		$results = [ $status->results ];
		$cache->freeze( $station, $results );
	}

	return @{$results};
}

get '/' => sub {
	my $self    = shift;
	my $station = $self->param('station');

	$self->stash( 'version', $VERSION );

	if ( not $station ) {
		return $self->render;
	}
	$self->redirect_to("/${station}");
} => 'index';

get '/:station' => sub {
	my $self    = shift;
	my $station = $self->stash('station');

	my @params;
	my $template = HTML::Template->new(
		filename          => dist_file( 'db-fakedisplay', 'multi-lcd.html' ),
		loop_context_vars => 1,
	);
	my @results = get_results_for($station);

	$self->stash( 'version', $VERSION );

	if ( not @results ) {
		$self->render( 'index', error => "Got no results for '$station'", );
		return;
	}

	for my $result (@results) {
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
	$template->param(
		departures => \@params,
		version    => $VERSION
	);

	$self->render( text => $template->output );
};

get '/multi/:station' => sub {
	my $self    = shift;
	my $station = $self->stash('station');
	$self->redirect_to("/${station}");
};

app->start();

__DATA__

@@ index.html.ep
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
	"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
	<title>DB Fakedisplay</title>
	<meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
	<style type="text/css">

body {
	font-family: Sans-Serif;
}

p.about {
	color: #666666;
}

p.about a {
	color: #000066;
	text-decoration: none;
}

	</style>
</head>
<body>
<div>
<p>
DB-Fakedisplay displays the next departures at a DB station, just like the big
LC display in the station itself.
</p>

<% if (my $error = stash 'error') { %>
  Error: <%= $error %><br/>
<% } %>
<%= form_for index => begin %>
<p>
  Station name:<br/>
  <%= text_field 'station' %><br/>
  <%= submit_button 'Display' %>
</p>
<% end %>

<p>
(For example: "Koeln Hbf" or "Essen West")
</p>

<p class="about">
This is <a
href="http://finalrewind.org/projects/db-fakedisplay/">db-fakedisplay</a>
v<%= $version %>
</p>

</div>
</body>
</html>
