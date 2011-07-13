#!/usr/bin/env perl

use strict;
use warnings;
use Module::Build;

Module::Build->new(

	build_requires => {
		'Module::Build' => '0.36',
	},
	dist_name => 'db-fakedisplay',
	dist_version_from => 'bin/db-fakedisplay',
	license => 'unrestricted',
	requires => {
		'perl' => '5.10.0',
		'File::ShareDir' => 0,
		'HTML::Template' => 0,
		'List::Util' => 0,
		'Travel::Status::DE::DeutscheBahn' => '0.04',
	},
	share_dir => 'share',
	sign => 1,

)->create_build_script();
