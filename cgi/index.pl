#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
use Travel::Status::DE::DeutscheBahn;

our $VERSION = '0.01';

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

	my @platforms = split(/,/, $self->param('platforms') // q{});
	my $template = $self->param('mode') // 'multi';

	$self->stash( departures => [] );
	$self->stash( title      => 'db-fakedisplay' );
	$self->stash( version    => $VERSION );

	if (not($template ~~ [qw[multi single]])) {
		$template = 'multi';
	}

	if ( not $station ) {
		$self->render($template);
		return;
	}

	my @departures;
	my @results = get_results_for($station);

	if ( not @results ) {
		$self->render( 'multi', error => "Got no results for '$station'" );
		return;
	}

	if ($template eq 'single') {
		if (not @platforms) {
			for my $result (@results) {
				if (not ($result->platform ~~ \@platforms)) {
					push(@platforms, $result->platform);
				}
			}
			@platforms = sort { $a <=> $b } @platforms;
		}
		my %pcnt;
		@results = grep { $pcnt{$_->platform}++ < 1 } @results;
		@results = sort { $a->platform <=> $b->platform } @results;
	}

	for my $result (@results) {
		my $platform = ( split( / /, $result->platform ) )[0];
		if ($via) {
			my @route = $result->route;
			if (not( grep { $_ =~ m{$via}io } @route )) {
				next;
			}
		}
		if (@platforms and not grep { $_ eq $platform } @platforms) {
			next;
		}
		push(
			@departures,
			{
				time        => $result->time,
				train       => $result->train,
				via         => [ $result->route_interesting(3) ],
				destination => $result->destination,
				platform    => $platform,
				info        => $result->info,
			}
		);
	}

	$self->render(
		$template,
		departures => \@departures,
		version    => $VERSION,
		title      => "departures for ${station}"
	);
}

get '/_redirect' => sub {
	my $self    = shift;
	my $station = $self->param('station');
	my $via     = $self->param('via');
	my $params  = $self->req->params;

	$params->remove('station');
	$params->remove('via');

	for my $param (qw(platforms)) {
		if (not $params->param($param)) {
			$params->remove($param);
		}
		elsif ($param eq 'mode' and $params->param($param) eq 'multi') {
			$params->remove($param);
		}
	}

	$params = $params->to_string;

	if ($via) {
		$self->redirect_to("/${station}/${via}?${params}");
	}
	else {
		$self->redirect_to("/${station}?${params}");
	}
};

app->defaults( layout => 'default' );

get '/'               => \&handle_request;
get '/:station'       => \&handle_request;
get '/:station/:via'  => \&handle_request;
get '/multi/:station' => \&handle_request;

app->config(
	hypnotoad => {
		accepts => 10,
		listen => ['http://*:8092'],
		pid_file => '/tmp/db-fake.pid',
		workers => 2,
	},
);

app->start();

__DATA__

@@ layouts/default.html.ep
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
	"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
	<title><%= $title %></title>
	<meta http-equiv="Content-Type" content="text/html;charset=iso-8859-1"/>
	<style type="text/css">

	html {
		font-family: Sans-Serif;
	}

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

	div.input-field {
		margin-top: 1em;
		clear: both;
	}

	span.fielddesc {
		display: block;
		float: left;
		width: 15em;
		text-align: right;
		padding-right: 0.5em;
	}

	input, select {
		border: 1px solid #000066;
	}

	div.s_display {
		background-color: #0000ff;
		color: white;
		font-family: Sans-Serif;
		font-weight: bold;
		position: relative;
		margin-left: 1em;
		margin-top: 1em;
		float: left;
		width: 28em;
		height: 4.5em;
		border: 0.7em solid #000066;
	}

	div.s_display div {
		overflow: hidden;
		position: absolute;
	}

	div.s_no_data {
		top: 0.5em;
		left: 1em;
		font-size: 1.7em;
	}

	div.s_time {
		top: 0em;
		left: 0em;
		font-size: 1.7em;
	}

	div.s_train {
		left: 0em;
		top: 1.8em;
	}

	div.s_via {
		top: 1.5em;
		left: 5.8em;
		width: 17em;
		height: 1em;
	}

	div.s_via span {
		margin-right: 0.4em;
	}

	div.s_destination {
		top: 1.6em;
		left: 3.6em;
		width: 12em;
		font-size: 1.6em;
		height: 1.2em;
	}

	div.s_platform {
		top: 0em;
		right: 0em;
		font-size: 3em;
	}

	div.s_info {
		top: 0em;
		left: 5.8em;
		width: 16.5em;
		height: 1em;
		background-color: white;
		color: #0000ff;
	}

	</style>
</head>
<body>

<%= content %>

<div class="input-field">

<% if (my $error = stash 'error') { %>
<p>
  Error: <%= $error %><br/>
</p>
<% } %>

<%= form_for _redirect => begin %>
<p>
  <span class="fielddesc">Station name</span>
  <%= text_field 'station' %>
  <br/>
  <span class="fielddesc fieldoptional">only display routes via</span>
  <%= text_field 'via' %>
  (optional)
  <br/>
  <span class="fielddesc fieldoptional">on platforms</span>
  <%= text_field 'platforms' %>
  (optional)
  <br/>
  <span class="fielddesc fieldoptional">display type</span>
  <%= select_field mode => [['combined' => 'multi'], ['platform' => 'single']] %>
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

@@ multi.html.ep
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

@@ single.html.ep

% if (@{$departures}) {

% my $i = 0;
% for my $departure (@{$departures}) {
% $i++;
<div class="s_display">
<div class="s_platform">
%= $departure->{platform}
</div>
<div class="s_time">
%= $departure->{time}
</div>
<div class="s_train">
%= $departure->{train}
</div>
<div class="s_via">
% my $via_max = @{$departure->{via}};
% my $via_cur = 0;
% for my $stop (@{$departure->{via}}) {
% $via_cur++;
<span><%= $stop %><% if ($via_cur < $via_max) { %> - <% } %></span>
% }
</div>
<div class="s_destination">
%= $departure->{destination}
</div>
% if ($departure->{info}) {
<div class="s_info">
%= $departure->{info}
</div>
% }
</div> <!-- s_display -->
% }

% }
% else {

<div class="s_display">
<div class="s_no_data">
Bitte Ansage beachten
</div>
</div>

<p>
DB-Fakedisplay displays the next departures at a DB station, just like the big
LC display in the station itself.
</p>

% }

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
