#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
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

sub handle_request {
	my $self    = shift;
	my $station = $self->stash('station');
	my $via     = $self->stash('via');

	$self->stash( departures => [] );
	$self->stash( title      => 'db-fakedisplay' );
	$self->stash( version    => $VERSION );

	if ( not $station ) {
		$self->render('multi');
		return;
	}

	my @departures;
	my @results = get_results_for($station);

	if ( not @results ) {
		$self->render( 'multi', error => "Got no results for '$station'" );
		return;
	}

	for my $result (@results) {
		if ($via) {
			my @route = $result->route;
			if (not( grep { $_ =~ m{$via}io } @route )) {
				next;
			}
		}
		push(
			@departures,
			{
				time        => $result->time,
				train       => $result->train,
				via         => [ $result->route_interesting(3) ],
				destination => $result->destination,
				platform    => ( split( / /, $result->platform ) )[0],
				info        => $result->info,
			}
		);
	}

	$self->render(
		'multi',
		departures => \@departures,
		version    => $VERSION,
		title      => "departures for ${station}"
	);
}

get '/_redirect' => sub {
	my $self    = shift;
	my $station = $self->param('station');
	my $via     = $self->param('via');

	if ($via) {
		$self->redirect_to("/${station}/${via}");
	}
	else {
		$self->redirect_to("/${station}");
	}
};

get '/'               => \&handle_request;
get '/:station'       => \&handle_request;
get '/:station/:via'  => \&handle_request;
get '/multi/:station' => \&handle_request;

app->start();

__DATA__

@@ multi.html.ep
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
	"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
	<title><%= $title %></title>
	<meta http-equiv="Content-Type" content="text/html;charset=iso-8859-1"/>
	<style type="text/css">

	div.outer {
		border: 0.2em solid #000066;
		width: 55em;
	}

	div.display {
		background-color: #0000ff;
		color: white;
		font-family: Sans-Serif;
		font-weight: bold;
		position: relative;
		margin-bottom: 0;
		margin-top: 0;
		padding-top: 0;
		padding-bottom: 0;
		width: 55em;
		height: 1.4em;
	}

	div.display div {
		overflow: hidden;
		position: absolute;
		height: 100%;
	}

	div.time {
		left: 0;
		width: 6%;
		font-size: 95%;
	}

	div.train {
		left: 5%;
		width: 9%;
		background-color: white;
		color: #0000ff;
		font-size: 95%;
	}

	div.via {
		left: 15%;
		width: 35%;
	}

	div.via span {
		margin-right: 0.4em;
		font-size: 80%;
	}

	div.destination {
		left: 50%;
		width: 25%;
		font-size: 120%;
	}

	div.platform {
		left: 75%;
		width: 5%;
	}

	div.info {
		left: 80%;
		width: 20%;
		background-color: white;
		color: #0000ff;
		font-size: 80%;
		line-height: 150%;
	}

	div.separator {
		border-bottom: 0.1em solid #000066;
	}

	div.about {
		font-family: Sans-Serif;
		color: #666666;
	}

	div.about a {
		color: #000066;
	}

	</style>
</head>
<body>

% if (@{$departures}) {

<div class="outer">
% my $i = 0;
% for my $departure (@{$departures}) {
% $i++;

<div class="display <% if (($i % 2) == 0) { %> separator<% } %>">
<div class="platform">
%= $departure->{platform}
</div>

<div class="time">
%= $departure->{time}
</div>

<div class="train">
%= $departure->{train}
</div>

<div class="via">
% my $via_max = @{$departure->{via}};
% my $via_cur = 0;
% for my $stop (@{$departure->{via}}) {
% $via_cur++;
<span><%= $stop %><% if ($via_cur < $via_max) { %> - <% } %></span>
% }
</div>

<div class="destination">
%= $departure->{destination}
</div>

% if ($departure->{info}) {
<div class="info">
%= $departure->{info}
</div>
% }

</div> <!-- display -->

% }

</div> <!-- outer -->

% }
% else {

<p>
DB-Fakedisplay displays the next departures at a DB station, just like the big
LC display in the station itself.
</p>

% }

<div class="input-field">

<% if (my $error = stash 'error') { %>
<p>
  Error: <%= $error %><br/>
</p>
<% } %>

<%= form_for _redirect => begin %>
<p>
  Station name:
  <%= text_field 'station' %>
  <%= submit_button 'Display' %>
</p>
<% end %>

</div>

<div class="about">
<a href="http://finalrewind.org/projects/db-fakedisplay/">db-fakedisplay</a>
v<%= $version %>
</div>

</body>
</html>

@@ not_found.html.ep
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
	"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
	<title>page not found</title>
	<meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
</head>
<body>
<div>
page not found
</div>
</body>
</html>
