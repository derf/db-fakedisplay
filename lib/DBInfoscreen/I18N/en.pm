package DBInfoscreen::I18N::en;

# Copyright (C) 2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'DBInfoscreen::I18N';

our %Lexicon = (

	# common
	'Stationen in der Umgebung suchen' => 'Find stops nearby',

	# layouts/app
	'Mehrdeutige Eingabe'                        => 'Ambiguous input',
	'Bitte eine Station aus der Liste auswählen' =>
	  'Please select a station from the list',
	'Zug / Station' => 'Enter train number or station name',
	'Zug, Stationsname oder Ril100-Kürzel' =>
	  'train, station name, or DS100 code',
	'Abfahrtstafel'                           => 'Show departures',
	'Weitere Einstellungen'                   => 'Preferences',
	'Zeiten inkl. Verspätung angeben'         => 'Include delay in timestamps',
	'Verspätungen erst ab 5 Minuten anzeigen' => 'Hide delays below 5 minutes',
	'Mehr Details'                            => 'Verbose mode',
'Betriebliche Bahnhofstrennungen berücksichtigen (z.B. "Hbf (Fern+Regio)" vs. "Hbf (S)")'
	  => 'Respect split stations; do not join them',
	'Bereits abgefahrene Züge anzeigen'              => 'Include past trains',
	'Formular verstecken'                            => 'Hide form',
	'Nur Züge über'                                  => 'Only show trains via',
	'Bahnhof 1, Bhf2, ... (oder regulärer Ausdruck)' =>
	  'Station 1, 2, ... (or regular expression)',
	'Gleise'                                => 'Platforms',
	'Ankunfts- oder Abfahrtszeit anzeigen?' => 'Show arrival or departure?',
	'Abfahrt bevorzugen'                    => 'prefer departure',
	'Nur Abfahrt'                           => 'departure only',
	'Nur Ankunft'                           => 'arrival only',
	'Anzeigen'                              => 'Submit',
	'Datenschutz'                           => 'Privacy',
	'Impressum'                             => 'Imprint',

	# landing page
	'Oder hier angeben:' => 'Or enter manually:',

	# train details
	'Gleis'                         => 'Platform',
	'An:'                           => 'Arr',
	'Ab:'                           => 'Dep',
	'Plan:'                         => 'Sched',
	'Auslastung unbekannt'          => 'Occupancy unknown',
	'Geringe Auslastung'            => 'Low occupancy',
	'Hohe Auslastung'               => 'High occupancy',
	'Sehr hohe Auslastung'          => 'Very high occupancy',
	'Zug ist ausgebucht'            => 'Fully booked',
	'Geringe Auslastung erwartet'   => 'Low occupancy expected',
	'Hohe Auslastung erwartet'      => 'High occupancy expected',
	'Sehr hohe Auslastung erwartet' => 'Very high occupancy expected',
	'Meldungen'                     => 'Messages',
	'Fahrtverlauf am'               => 'Route on',
	'Betrieb'                       => 'Operator',
	'Karte'                         => 'Map',
	'Wagen'                         => 'Composition',

	# wagon order
	'Nach'         => 'To',
	'in Abschnitt' => 'in sections',
	'Wagen '       => 'carriage ',

	# map
	'Fahrt'                  => 'Trip',
	'von'                    => 'from',
	'nach'                   => 'to',
	'Nächster Halt:'         => 'Next stop:',
	'um'                     => 'at',
	'auf Gleis'              => 'on platform',
	'Aufenthalt in'          => 'Stopped in',
	'an Gleis'               => 'on platform',
	'bis'                    => 'until',
	'Abfahrt in'             => 'Departs',
	'von Gleis'              => 'from platform',
	'Endstation erreicht um' => 'Terminus reached at',
);

1;
