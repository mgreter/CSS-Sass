# -*- perl -*-

# Usefult for debugging the xs with prints:
# cd text-sass-xs && ./Build && perl -Mlib=blib/arch -Mlib=blib/lib t/04_perl_functions.t

use strict;
use warnings;

my (@dirs, @tests);

BEGIN
{

	@dirs = ('t/sass-spec/spec');

	while (my $dir = shift(@dirs))
	{
		opendir(my $dh, $dir) or die "error opening specs dir $dir";
		while (my $ent = readdir($dh))
		{
			next if $ent eq ".";
			next if $ent eq "..";
			next if $ent eq "todo";
			my $path = join("/", $dir, $ent);
			push @dirs, $path if -d $path;
			push @tests, [$dir, $ent] if $ent =~ m/^input/;
		}
		closedir($dh);
	}

	# warn join(", ", map { $_->[0] } @tests), "\n";

}

use Test::More tests => scalar(@tests) * 2;

use CSS::Sass;

sub read_file
{
  local $/ = undef;
  open my $fh, "<:raw", $_[0] or die "Couldn't open file: $!";
  binmode $fh; return <$fh>;
}

my $sass;
my ($r, $err);
my ($src, $expect);
my $ignore_whitespace = 1;

foreach my $test (@tests)
{
	my $input_file = join("/", @{$test});
	my $expected_file = join("/", $test->[0], 'expected_output.css');

	$sass = CSS::Sass->new(include_paths => ['t/inc'], output_style => SASS_STYLE_NESTED);
	$r = eval { $sass->compile_file($input_file) };
	warn $@ if $@;
	$expect = read_file($expected_file);
	$expect =~ s/[\r\n]+/\n/g if $ignore_whitespace;
	$r =~ s/[\r\n]+/\n/g if $ignore_whitespace;
	chomp($expect) if $ignore_whitespace;
	chomp($r) if $ignore_whitespace;

	is    ($r, $expect,                                    "sass-spec " . $input_file);
	is    ($err, undef,                                    "sass-spec " . $input_file);

}
