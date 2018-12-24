
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

=head1 NAME

Bio::EnsEMBL::Xref::Mapper::ProcessMappings

=cut

=head1 DESCRIPTION

Mapper class with a set of subroutines used for creating Xrefs based on
coordinate overlaps.

=cut

package Bio::EnsEMBL::Xref::Mapper::ProcessMappings;

use strict;
use warnings;

use Bio::EnsEMBL::DBSQL::DBAdaptor;

use Carp;
use Cwd;
use DBI;
use File::Basename;
use IPC::Open3;

use parent qw( Bio::EnsEMBL::Xref::Mapper );

=head2 process_mappings

  Description: Main routine that processes alignments
               from the exonerate mapping files
               Include checks
               Saves all data to object_xref and processes dependents
               Process priority xrefs to leave those excluded flagged as such
               Do tests on xref database wrt to core before saving data.

  Return type: None
  Caller     : Bio::EnsEMBL::Production::Pipeline::Xrefs::ProcessMappings

=cut

sub process_mappings {
  my ($self) = @_;

  # get the jobs from the mapping table
  # for i =1 i < jobnum{
  #   if( Not parsed already see mapping_jobs){
  #     check the .err, .out and .map files in that order.
  #     put data into object_xref, identity_xref, go_xref etc... 
  #     add data to mapping_job table
  #   }
  # }

  my %query_cutoff;
  my %target_cutoff;
  my ($job_id, $percent_query_cutoff, $percent_target_cutoff);
  my $xref_dbh = $self->xref->dbc()->db_handle();
  my $sth = $xref_dbh->prepare("select job_id, percent_query_cutoff, percent_target_cutoff from mapping");
  $sth->execute();
  $sth->bind_columns(\$job_id, \$percent_query_cutoff, \$percent_target_cutoff);

  while($sth->fetch){
    $query_cutoff{$job_id} = $percent_query_cutoff;    
    $target_cutoff{$job_id} = $percent_target_cutoff;
  }
  $sth->finish;

  my ($root_dir, $map, $status, $out, $err, $array_number); 
  my ($map_file, $out_file, $err_file);
  my $map_sth = $xref_dbh->prepare("select root_dir, map_file, status, out_file, err_file, array_number, job_id from mapping_jobs");
  $map_sth->execute();
  $map_sth->bind_columns(\$root_dir, \$map, \$status, \$out, \$err, \$array_number, \$job_id);
  my $already_processed_count = 0;
  my $processed_count = 0;
  my $error_count = 0;
  my $empty_count = 0;

  my $stat_sth = $xref_dbh->prepare("update mapping_jobs set status = ? where job_id = ? and array_number = ?");

  while ( $map_sth->fetch() ) {
    my $err_file = $root_dir."/".$err;
    my $out_file = $root_dir."/".$out;
    my $map_file = $root_dir."/".$map;
    if ( $status eq "SUCCESS" ) {
      $already_processed_count++;
    }
    else {
      if ( -s $err_file ) {
        $error_count++;
        confess "Problem $err_file is non zero";
      }
      else { #err file checks out so process the mapping file.
        if ( -e $map_file ) {
          my $count = $self->process_map_file($map_file, $query_cutoff{$job_id}, $target_cutoff{$job_id}, $job_id, $array_number, $root_dir);
          if ( $count > 0 ) {
            $processed_count++;
            $stat_sth->execute('SUCCESS',$job_id, $array_number);
          }
          elsif ( $count ==0 ) {
            $processed_count++;
            $empty_count++;
            $stat_sth->execute('SUCCESS',$job_id, $array_number);
          }  
          else {
            $error_count++;
            $stat_sth->execute('FAILED',$job_id, $array_number);
          }  
        }
        else {
          $error_count++;
          confess "Could not open file $map_file???\n Resubmit this job";
        }
      }      
    }
  }
  $map_sth->finish;
  $stat_sth->finish;

  if ( $self->verbose ) {
    print "already processed = $already_processed_count, ";
    print "processed = $processed_count, ";
    print "errors = $error_count, ";
    print "empty = $empty_count\n";
  }

  if ( !$error_count ) {
    my $sth = $xref_dbh->prepare("insert into process_status (status, date) values('mapping_processed',now())");
    $sth->execute();
    $sth->finish;
  }

  return;
}

=head2 process_map_file

  Arg [1]    : alignment file
  Arg [2]    : cutoff for query string
  Arg [3]    : cutoff for target string
  Arg [4]    : ID for the job
  Arg [5]    : Position in the array
  Description: Parse alignment file and store the results
  Return type: None
  Caller     : internal

=cut


#return number of lines parsed if succesfull. -1 for fail
sub process_map_file {
  my ($self, $map_file, $query_cutoff, $target_cutoff, $job_id, $array_number, $root_dir) = @_;

  my $ensembl_type = "Translation";
  if ( $map_file =~ /dna_/ ) {
    $ensembl_type = "Transcript";
  }
 
  my $mh;
  open ($mh ,"<",$map_file) or confess "Could not open file $map_file";
  my $total_lines = $self->_process_file($mh, $query_cutoff, $target_cutoff, $job_id, $array_number, $root_dir, $ensembl_type);
  close $mh;

  return $total_lines;
}

=head2 _process_file

  Description: Process alignment file
  Return type: None
  Caller     : internal

=cut

sub _process_file {

  my ($self, $mh, $query_cutoff, $target_cutoff, $job_id, $array_number, $root_dir, $ensembl_type) = @_;
  my $xref_dbh = $self->xref->dbc()->db_handle();

  my $object_xref_id;
  my $sth = $xref_dbh->prepare("select max(object_xref_id) from object_xref");
  $sth->execute();
  $sth->bind_columns(\$object_xref_id);
  $sth->fetch();
  $sth->finish;
  if ( !defined($object_xref_id) ) {
    $object_xref_id = 0;
  }

  my $total_lines = 0;

  my $ins_go_sth = $xref_dbh->prepare("insert ignore into go_xref (object_xref_id, linkage_type, source_xref_id) values(?,?,?)");
  my $start_sth  = $xref_dbh->prepare("update mapping_jobs set object_xref_start = ? where job_id = ? and array_number = ?");
  my $end_sth    = $xref_dbh->prepare("update mapping_jobs set object_xref_end = ? where job_id = ? and array_number = ?");

  my $object_xref_sth = $xref_dbh->prepare("insert into object_xref (ensembl_id,ensembl_object_type, xref_id, linkage_type, ox_status ) values (?, ?, ?, ?, ?)");
  my $get_object_xref_id_sth = $xref_dbh->prepare("select object_xref_id from object_xref where ensembl_id = ? and ensembl_object_type = ? and xref_id = ? and linkage_type = ? and ox_status = ?");
  local $object_xref_sth->{RaiseError}; #catch duplicates
  local $object_xref_sth->{PrintError}; # cut down on error messages

  my $identity_xref_sth = $xref_dbh->prepare("insert ignore into identity_xref (object_xref_id, query_identity, target_identity, hit_start, hit_end, translation_start, translation_end, cigar_line, score ) values (?, ?, ?, ?, ?, ?, ?, ?, ?)");

  my $last_query_id = 0;
  my $best_match_found = 0;
  my $best_identity = 0;
  my $best_score = 0;

  my $first = 1;

  while ( <$mh> ) {
    my $load_object_xref = 0;
    $total_lines++;
    chomp();
    my ($label, $query_id, $target_id, $identity, $query_length, $target_length, $query_start, $query_end, $target_start, $target_end, $cigar_line, $score) = split(/:/, $_);

    if ( $last_query_id != $query_id ) {
      $best_match_found = 0;
      $best_score = 0;
      $best_identity = 0;
    }
    else {

      #ignore mappings with worse identity or score if we already found a good mapping
      if ( ($identity < $best_identity || $score < $best_score) && $best_match_found ) {
        next;
      }
    }

    if ( $ensembl_type eq "Translation" ) {
      $load_object_xref = 1;
    }
    else {
      $load_object_xref = $self->_check_biotype($query_id, $target_id);
    }

    $last_query_id = $query_id;

    if ( $score > $best_score || $identity > $best_identity ) {
      $best_score = $score;
      $best_identity = $identity;
    }

    if ( !$load_object_xref ) {
      next;
    }
    else {
      $best_match_found = 1;
    }

    if ( !defined($score) ) {
      $end_sth->execute(($object_xref_id),$job_id, $array_number);
      confess "No score on line. Possible file corruption\n$_";
    }

    # calculate percentage identities
    my $query_identity = int (100 * $identity / $query_length);
    my $target_identity = int (100 * $identity / $target_length);

    my $status = "DUMP_OUT";
    # Only keep alignments where both sequences match cutoff
    if ( $query_identity < $query_cutoff or $target_identity < $target_cutoff ) {
      $status = "FAILED_CUTOFF";
    }    

    $object_xref_sth->execute($target_id, $ensembl_type, $query_id, 'SEQUENCE_MATCH', $status) ;
    $get_object_xref_id_sth->execute($target_id, $ensembl_type, $query_id, 'SEQUENCE_MATCH', $status);
    $object_xref_id = ($get_object_xref_id_sth->fetchrow_array())[0];
    if ( $object_xref_sth->err ) {
      my $err = $object_xref_sth->errstr;
      if ( $err =~ /Duplicate/ ) {
        # can get match from same xref and ensembl entity e.g.
        # ensembl/ExonerateGappedBest1_dna_569.map:xref:934818:155760:54:1617:9648:73:12:3456:3517: M 61:242
        # ensembl/ExonerateGappedBest1_dna_569.map:xref:934818:151735:58:1617:10624:73:6:5329:5397: M 48 D 1 M 19:242
        next;
      }
      else{
        $end_sth->execute(($object_xref_id),$job_id, $array_number);
        confess "Problem loading error is $err\n";
      } 
    }  
    if ( $first ) {
      $start_sth->execute($object_xref_id,$job_id, $array_number);
      $first = 0;
    }

    $cigar_line =~ s/ //g;
    $cigar_line =~ s/([MDI])(\d+)/$2$1/ig;

    if ( !$identity_xref_sth->execute($object_xref_id, $query_identity, $target_identity, $query_start+1, $query_end, $target_start+1, $target_end, $cigar_line, $score) ) {
      $end_sth->execute(($object_xref_id),$job_id, $array_number);
      confess "Problem loading identity_xref";
    }

    $self->process_dependents($query_id, $target_id, $ensembl_type, $status, $job_id, $array_number, $query_identity, $target_identity);
  } 
  $end_sth->execute($object_xref_id,$job_id, $array_number);
  $start_sth->finish;
  $end_sth->finish;
  $ins_go_sth->finish;
  $object_xref_sth->finish;
  $identity_xref_sth->finish;

  return $total_lines;
}

=head2 _check_biotype

  Description: Alignments are processed depending on biotype
  Return type: None
  Caller     : internal

=cut

sub _check_biotype {

  my ($self, $query_id, $target_id) = @_;
  my $load_object_xref = 0;

  my $xref_dbh = $self->xref->dbc()->db_handle();
  my $source_name_sth = $xref_dbh->prepare("select s.name from xref x join source s using(source_id) where x.xref_id = ?");
  my $biotype_sth = $xref_dbh->prepare("select biotype from transcript_stable_id where internal_id = ?");

  my %mRNA_biotypes = (
      'protein_coding'          => 1,
      'TR_C_gene'               => 1,
      'IG_V_gene'               => 1,
      'nonsense_mediated_decay' => 1,
      'polymorphic_pseudogene'  => 1
  );

  #check if source name is RefSeq_ncRNA or RefSeq_mRNA
  #if yes check biotype, if ok store object xref
  $source_name_sth->execute($query_id);
  my ($source_name)  = $source_name_sth->fetchrow_array;

  if ( $source_name && ($source_name =~ /^RefSeq_(m|nc)RNA/ || $source_name =~ /^miRBase/ || $source_name =~ /^RFAM/) ) {

    #make sure mRNA xrefs are matched to protein_coding biotype only
    $biotype_sth->execute($target_id);
    my ($biotype) = $biotype_sth->fetchrow_array;

    if ( $source_name =~ /^RefSeq_mRNA/ && exists($mRNA_biotypes{$biotype}) ) {
      $load_object_xref = 1;
    }
    if ( $source_name =~ /^RefSeq_ncRNA/ && !exists($mRNA_biotypes{$biotype}) ) {
      $load_object_xref = 1;
    }
    if ( ($source_name =~ /miRBase/ || $source_name =~ /^RFAM/) && $biotype =~ /RNA/ ) {
      $load_object_xref = 1;
    }
  }
  else {
    $load_object_xref = 1;
  }

  return $load_object_xref;

}

=head2 process_dependents

  Description: Ensure dependent_xrefs are correctly added
  Return type: None
  Caller     : internal

=cut

sub process_dependents {
  my ($self, $query_id, $target_id, $ensembl_type, $status, $job_id, $array_number, $query_identity, $target_identity) = @_;

  my $xref_dbh = $self->xref->dbc()->db_handle();
  my $dep_sth    = $xref_dbh->prepare("select dependent_xref_id, linkage_annotation from dependent_xref where master_xref_id = ?");
  my $object_xref_sth2 = $xref_dbh->prepare("insert into object_xref (ensembl_id,ensembl_object_type, xref_id, linkage_type, ox_status, master_xref_id ) values (?, ?, ?, ?, ?, ?)");
  local $object_xref_sth2->{RaiseError}; #catch duplicates
  local $object_xref_sth2->{PrintError}; # cut down on error messages
  my $get_object_xref_id_master_sth = $xref_dbh->prepare("select object_xref_id from object_xref where ensembl_id = ? and ensembl_object_type = ? and xref_id = ? and linkage_type = ? and ox_status = ? and master_xref_id = ?");
  my $end_sth    = $xref_dbh->prepare("update mapping_jobs set object_xref_end = ? where job_id = ? and array_number = ?");
  my $ins_dep_ix_sth = $xref_dbh->prepare("insert ignore into identity_xref (object_xref_id, query_identity, target_identity) values(?, ?, ?)");

  my (@master_xref_ids, $object_xref_id);
  push @master_xref_ids, $query_id;
  while ( my $master_xref_id = pop(@master_xref_ids) ) {
    my ($dep_xref_id, $link);
    $dep_sth->execute($master_xref_id);
    $dep_sth->bind_columns(\$dep_xref_id, \$link);
    while ( $dep_sth->fetch ) {
      $object_xref_sth2->execute($target_id, $ensembl_type, $dep_xref_id, 'DEPENDENT', $status, $master_xref_id);
      $get_object_xref_id_master_sth->execute($target_id, $ensembl_type, $dep_xref_id, 'DEPENDENT', $status, $master_xref_id);
      $object_xref_id = ($get_object_xref_id_master_sth->fetchrow_array())[0];
      if ( $object_xref_sth2->err ) {
        my $err = $object_xref_sth2->errstr;
        if ( $err =~ /Duplicate/ ) {
          next;
        }
        else {
          $end_sth->execute($object_xref_id,$job_id, $array_number);
          confess "Problem loading error is $err";
        }
      }
      if ( $object_xref_sth2->err ) {
        confess "WARNING: Should not reach here??? object_xref_id = $object_xref_id";
      }

      $ins_dep_ix_sth->execute($object_xref_id, $query_identity, $target_identity);

      push @master_xref_ids, $dep_xref_id; # get the dependent, dependents just in case
    }
  }

  return;

}


1;
