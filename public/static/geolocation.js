$(document).ready(function() {
	var removeStatus = function() {
		$('div.candidatestatus').remove();
	};
	var showError = function(oneline, str) {
		var errnode = $(document.createElement('div'));
		errnode.attr('class', 'error');
		errnode.text(str);

		if (oneline) {
			var shortnode = $(document.createElement('div'));
			shortnode.attr('class', 'errshort');
			shortnode.text(oneline);
			errnode.append(shortnode);
		}

		$('div.candidatelist').append(errnode);
	};

	var processResult = function(data) {
		removeStatus();
		if (data.error) {
			showError('Backend-Fehler', data.error);
		} else if (data.candidates.length == 0) {
			showError(null, 'Keine Bahnhöfe in 70km Umkreis gefunden');
		} else {
			$.each(data.candidates, function(i, candidate) {

				var ds100 = candidate.ds100,
					name = candidate.name,
					distance = candidate.distance;
				distance = distance.toFixed(1);

				var stationlink = $(document.createElement('a'));
				stationlink.attr('href', ds100);
				stationlink.text(name);

				var distancenode = $(document.createElement('div'));
				distancenode.attr('class', 'distance');
				distancenode.text(distance);

				stationlink.append(distancenode);
				$('div.candidatelist').append(stationlink);
			});
		}
	};

	var processLocation = function(loc) {
		$.post('/_geolocation', {lon: loc.coords.longitude, lat: loc.coords.latitude}, processResult);
		$('div.candidatestatus').text('Suche Bahnhöfe…');
	};

	var processError = function(error) {
		removeStatus();
		if (error.code == error.PERMISSION_DENIED) {
			showError('geolocation.error.PERMISSION_DENIED', 'Standortanfrage nicht möglich. Vermutlich fehlen die Rechte im Browser oder der Android Location Service ist deaktiviert.');
		} else if (error.code == error.POSITION_UNAVAILABLE) {
			showError('geolocation.error.POSITION_UNAVAILABLE', 'Standort konnte nicht ermittelt werden (Service nicht verfügbar)');
		} else if (error.code == error.TIMEOUT) {
			showError('geolocation.error.TIMEOUT', 'Standort konnte nicht ermittelt werden (Timeout)');
		} else {
			showError('unknown geolocatior.error code', 'Standort konnte nicht ermittelt werden (unbekannter Fehler)');
		}
	};

	if (navigator.geolocation) {
		navigator.geolocation.getCurrentPosition(processLocation, processError);
		$('div.candidatestatus').text('Position wird bestimmt…');
	} else {
		removeStatus();
		showError(null, 'Standortanfragen werden von diesem Browser nicht unterstützt');
	}
});
