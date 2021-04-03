/*
 * Copyright (C) 2020 Daniel Friesel
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

$(function() {
	var removeStatus = function() {
		$('div.candidatestatus').remove();
	};
	var showError = function(header, message, code) {
		var errnode = $(document.createElement('div'));
		errnode.attr('class', 'error');
		errnode.text(message);

		var headnode = $(document.createElement('strong'));
		headnode.text(header);
		errnode.prepend(headnode);

		if (code) {
			var shortnode = $(document.createElement('div'));
			shortnode.attr('class', 'errcode');
			shortnode.text(code);
			errnode.append(shortnode);
		}

		$('div.candidatelist').append(errnode);
	};

	var processResult = function(data) {
		removeStatus();
		if (data.error) {
			showError('Backend-Fehler:', data.error, null);
		} else if (data.evas.length == 0) {
			showError('Keine Bahnstrecke gefunden', '', null);
		} else if (data.trains.length == 0) {
			showError('Keine Züge auf der Strecke gefunden', '', null);
		} else {
			$.each(data.trains, function(i, train) {

				const prev = train.stops[0][1]
				const prev_time = train.stops[0][2]
				const next_eva = train.stops[1][0]
				const next = train.stops[1][1]
				const next_time = train.stops[1][2]

				var stationlink = $(document.createElement('a'));
				stationlink.attr('href', '/z/' + train.train + '/' + next_eva);
				stationlink.text(train.line);

				var distancenode = $(document.createElement('div'));
				distancenode.attr('class', 'traininfo');
				distancenode.html(train.likelihood + '%<br/>' + prev_time + ' ' + prev + '<br/>' + next_time + ' ' + next);

				stationlink.append(distancenode);
				$('div.candidatelist').append(stationlink);
			});
		}
	};

	var processLocation = function(loc) {
		$.get('https://dbf.finalrewind.org/__geotrain/search', {lon: loc.coords.longitude, lat: loc.coords.latitude}, processResult).fail(function(jqXHR, textStatus, errorThrown) {
			removeStatus();
			showError("Fehler im Zuglokalisierungs-Backend: ", textStatus, errorThrown);
		});
		$('div.candidatestatus').text('Suche Züge…');
	};

	var processError = function(error) {
		removeStatus();
		if (error.code == error.PERMISSION_DENIED) {
			showError('Standortanfrage nicht möglich.', 'Vermutlich fehlen die Rechte im Browser oder der Android Location Service ist deaktiviert.', 'geolocation.error.PERMISSION_DENIED');
		} else if (error.code == error.POSITION_UNAVAILABLE) {
			showError('Standort konnte nicht ermittelt werden', '(Service nicht verfügbar)', 'geolocation.error.POSITION_UNAVAILABLE');
		} else if (error.code == error.TIMEOUT) {
			showError('Standort konnte nicht ermittelt werden', '(Timeout)', 'geolocation.error.TIMEOUT');
		} else {
			showError('Standort konnte nicht ermittelt werden', '(unbekannter Fehler)', 'unknown geolocation.error code');
		}
	};

	if (navigator.geolocation) {
		navigator.geolocation.getCurrentPosition(processLocation, processError);
		$('div.candidatestatus').text('Position wird bestimmt…');
	} else {
		removeStatus();
		showError('Standortanfragen werden von diesem Browser nicht unterstützt', '', null);
	}
});
