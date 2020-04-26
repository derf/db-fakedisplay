db-infoscreen - App/Infoscreen for Railway Departures in Germany
---

[db-infoscreen homepage](https://finalrewind.org/projects/db-fakedisplay/)

db-infoscreen (formerly db-fakedisplay) shows departures at german train
stations, serving both as infoscreen / webapp and station board look-alike.

Thanks to the undocumented IRIS backend, it usually has very detailed
information about delay reasons and service limitations.

There's a public [db-infoscreen service on
finalrewind.org](https://dbf.finalrewind.org/). You can also host your own
instance via carton/cpanminus or Docker if you like, see the Setup notes below.


Dependencies
---

 * perl >= 5.20
 * carton or cpanminus
 * build-essential
 * git

Installation
---

After installing the dependencies, clone the repository using git, e.g.

```
git clone https://git.finalrewind.org/db-fakedisplay
```

Make sure that all files (including `.git`, which is used to determine the
software version) are readable by your www user, and follow the steps in the
next sections.

Perl Dependencies
---

db-infoscreen depends on a set of Perl modules which are documented in
`cpanfile`. After installing the dependencies mentioned above, you can use
carton or cpanminus to install Perl depenencies locally.

In the project root directory (where `cpanfile` resides), run either

```
carton install
```

or

```
cpanm --installdeps .
```

and set `PERL5LIB=.../local/lib/perl5` before running index.pl or wrap it
with `carton exec hypnotoad index.pl`.

Note that you should provide imprint and privacy policy pages. Depending on
traffic volume, you may also want to increase the amount of worker processes.
See the Setup notes below.

Installation with Docker
---

A db-infoscreen image is available on Docker Hub. You can install and run it
as follows:

```
docker pull derfnull/db-fakedisplay:latest
docker run --rm -p 8000:8092 -v "$(pwd)/templates:/app/ext-templates:ro" db-fakedisplay:latest
```

This will make the web service available on port 8000.  Note that you should
provide imprint and privacy policy pages, see the Setup notes below.

Use `docker run -e DBFAKEDISPLAY_WORKERS=4 ...` and similar to pass environment
variables to the db-infoscreen service.

Setup
---

db-infoscreen respects the following environment variables:

| Variable | Default | Description |
| :------- | :------ | :---------- |
| DBFAKEDISPLAY\_LISTEN | `http://*:8092` | IP and Port for web service |
| DBFAKEDISPLAY\_STATS | _None_ | File in which the total count of backend API requests (excluding those answered from cache) is written |
| DBFAKEDISPLAY\_HAFAS\_CACHE | `/tmp/dbf-hafas` | Directory for HAFAS cache |
| DBFAKEDISPLAY\_IRIS\_CACHE | `/tmp/dbf-iris-mian` | Directory for IRIS schedule cache |
| DBFAKEDISPLAY\_IRISRT\_CACHE | `/tmp/dbf-iris-realtime` | Directory for IRIS realtime cache |
| DBFAKEDISPLAY\_WORKERS | 2 | Number of worker processes (i.e., maximum amount of concurrent requests) |

Set these as needed, create `templates/imprint.html.ep` (imprint) and
`templates/privacy.html.ep` (privacy policy), and configure your web server to
pass requests for db-infoscreen to the appropriate port. See the
`examples` directory for imprint and privacy policy samples.

You can run the app using a Mojo::Server of your choice, e.g.  **perl
index.pl daemon -m production** (quick&dirty, does not respect all variables)
or **hypnotad** (recommended). A systemd unit example is provided in
`examples/db-infoscreen.service`.

All code in this repository may be used under the terms of the BSD-2-Clause
(db-infoscreen, see COPYING) and MIT (jquery, jqueryui, and marquee libraries;
see the respective files) licenses.  Attribution is appreciated.

System requirements
---

Resource requirements depend on usage. For a few requests per second, about
200MB (600k inodes) cache and one or two CPU cores should be sufficient.
db-infoscreen typically needs 50MB RAM per worker process, though calculating
with 100MB per worker is recommended to leave a safety margin.
