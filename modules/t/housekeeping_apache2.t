=head1 LICENSE

See the NOTICE file distributed with this work for additional information
regarding copyright ownership.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.

=cut


use strict;
use warnings;


use Cwd;
use File::Spec;
use File::Basename qw/dirname/;
use Test::More;
use Test::Warnings;
use Bio::EnsEMBL::Test::TestUtils;

if ( not $ENV{TEST_AUTHOR} ) {
  my $msg = 'Author test. Set $ENV{TEST_AUTHOR} to a true value to run.';
  plan( skip_all => $msg );
}


#chdir into the file's target & request cwd() which should be fully resolved now.
#then go back
my $file_dir = dirname(__FILE__);
my $original_dir = cwd();
chdir($file_dir);
my $cur_dir = cwd();
chdir($original_dir);
my $root = File::Spec->catdir($cur_dir, File::Spec->updir(),File::Spec->updir());

my @source_files = map {all_source_code(File::Spec->catfile($root, $_))} qw(modules scripts sql docs);
#Find all files & run
foreach my $f (@source_files) {
    next if $f =~ /modules\/t\/test-genome-DBs\//;
    next if $f =~ /scripts\/synteny\/(apollo|BuildSynteny|SyntenyManifest.txt)/;
    next if $f =~ /\/blib\//;
    next if $f =~ /\/HALXS\.c$/;
    next if $f =~ /\.conf\b/;
    next if $f =~ /\/CLEAN\b/;
    next if $f =~ /\.(tmpl|hash|nw|ctl|txt|html|textile)$/;
    has_apache2_licence($f, 1);
}

done_testing();
