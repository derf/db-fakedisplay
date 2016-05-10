$(document).ready(function() {
	var removeStatus = function() {
		$('div.candidatestatus').remove();
	};
	var showError = function(str) {
		var errnode = $(document.createElement('span'));
		errnode.attr('class', 'error');
		errnode.text(str);
		$('div.candidatelist').append(errnode);
	};

	var processResult = function(data) {
		removeStatus();
		if (data.error) {
			showError(data.error);
		} else if (data.candidates.length == 0) {
			showError('Keine Bahnhöfe in 70km Umkreis gefunden');
		} else {
			$.each(data.candidates, function(i, candidate) {

				var ds100 = candidate[0][0],
					name = candidate[0][1],
					distance = candidate[1];
				distance = distance.toFixed(1);

				var stationlink = $(document.createElement('a'));
				stationlink.attr('href', ds100);
				stationlink.text(name);
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
			showError('Standortanfrage abglehnt. Vermutlich fehlen die Rechte im Browser oder der Android Location Service ist deaktiviert.');
		} else if (error.code == error.POSITION_UNAVAILABLE) {
			showError('Standort konnte nicht ermittelt werden (Service nicht verfügbar)');
		} else if (error.code == error.TIMEOUT) {
			showError('Standort konnte nicht ermittelt werden (Timeout)');
		} else {
			showError('Standort konnte nicht ermittelt werden (unbekannter Fehler)');
		}
	};

	if (navigator.geolocation) {
		navigator.geolocation.getCurrentPosition(processLocation, processError);
		$('div.candidatestatus').text('Position wird bestimmt…');
	} else {
		removeStatus();
		showError('Standortanfragen werden von diesem Browser nicht unterstützt');
	}
});
