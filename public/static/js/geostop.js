/*
 * Copyright (C) 2020 Birte Kristina Friesel
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

$(function() {
	const removeStatus = function() {
		$('div.candidatestatus').remove();
	};
	const showError = function(header, message, code) {
		const errnode = $(document.createElement('div'));
		errnode.attr('class', 'error');
		errnode.text(message);

		const headnode = $(document.createElement('strong'));
		headnode.text(header);
		errnode.prepend(headnode);

		if (code) {
			const shortnode = $(document.createElement('div'));
			shortnode.attr('class', 'errcode');
			shortnode.text(code);
			errnode.append(shortnode);
		}

		$('div.candidatelist').append(errnode);
	};

	const processResult = function(data) {
		removeStatus();
		if (data.error) {
			showError('Backend-Fehler:', data.error, null);
		} else if (data.candidates.length == 0) {
			showError('Keine Stationen in 70km Umkreis gefunden', '', null);
		} else {
			$.each(data.candidates, function(i, candidate) {

				const eva = candidate.eva,
					name = candidate.name,
					distance = candidate.distance.toFixed(1),
					efa = candidate.efa,
					hafas = candidate.hafas;

				const stationlink = $(document.createElement('a'));
				if (efa) {
					stationlink.attr('href', eva + '?efa=' + efa);
				} else if (hafas) {
					stationlink.attr('href', eva + '?hafas=' + hafas);
				} else {
					stationlink.attr('href', eva);
				}
				stationlink.text(name + ' ');

				const distancenode = $(document.createElement('div'));
				distancenode.attr('class', 'distance');
				distancenode.text(distance);

				const icon = $(document.createElement('i'));
				icon.attr('class', 'material-icons');
				icon.text((hafas || efa) ? 'directions' : 'train');

				stationlink.append(icon);
				stationlink.append(distancenode);
				$('div.candidatelist').append(stationlink);
			});
		}
	};

	const processLocation = function(loc) {
		const param = new URLSearchParams(window.location.search);
		$.post('/_geolocation', {lon: loc.coords.longitude, lat: loc.coords.latitude, efa: param.get('efa'), hafas: param.get('hafas')}, processResult).fail(function(jqXHR, textStatus, errorThrown) {
			removeStatus();
			showError("Netzwerkfehler: ", textStatus, errorThrown);
		});
		$('div.candidatestatus').text('Suche Stationen…');
	};

	const processError = function(error) {
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
