#
# $Id$
#
# BioPerl module for Bio::Index::BDB
#
# Cared for by Lincoln Stein <lstein@cshl.org>
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::DB::Flat::BDB - Interface for BioHackathon standard BDB-indexed flat file

=head1 SYNOPSIS

You should not be using this module directly

=head1 DESCRIPTION

This object provides the basic mechanism to associate positions in
files with primary and secondary name spaces. Unlike
Bio::Index::Abstract (see L<Bio::Index::Abstract), this is specialized
to work with the BerkeleyDB-indexed "common" flat file format worked
out at the 2002 BioHackathon.

This object is the guts to the mechanism, which will be used by the
specific objects inheriting from it.

=head1 FEEDBACK

=head2 Mailing Lists

User feedback is an integral part of the evolution of this and other
Bioperl modules. Send your comments and suggestions preferably to one
of the Bioperl mailing lists.  Your participation is much appreciated.

  bioperl-l@bioperl.org             - General discussion
  http://bioperl.org/MailList.shtml - About the mailing lists

=head2 Reporting Bugs

Report bugs to the Bioperl bug tracking system to help us keep track
the bugs and their resolution.  Bug reports can be submitted via
email or the web:

  bioperl-bugs@bio.perl.org
  http://bio.perl.org/bioperl-bugs/

=head1 AUTHOR - Lincoln Stein

Email - lstein@cshl.org

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal
methods are usually preceded with an "_" (underscore).

=cut


# Let the code begin...

package Bio::DB::Flat::BDB;

use strict;
use DB_File;
use IO::File;
use Fcntl qw(O_CREAT O_RDWR O_RDONLY);
use File::Spec;
use Bio::SeqIO;
use Bio::DB::RandomAccessI;
use Bio::Root::Root;
use Bio::Root::IO;
use vars '@ISA';

@ISA = qw(Bio::Root::Root Bio::DB::RandomAccessI);

use constant CONFIG_FILE_NAME => 'config.dat';

=head2 new

 Title   : new
 Usage   : my $db = new Bio::Index::BDB->new(
                     -directory  => $root_directory,
		     -write_flag => 0,
                     -verbose    => 0,
		     -out        => 'outputfile',
                     -format     => 'genbank');
 Function: create a new Bio::Index::BDB object
 Returns : new Bio::Index::BDB object
 Args    : -directory    Root directory containing "config.dat"
           -write_flag   If true, allows reindexing.
           -verbose      Verbose messages
           -maxopen      Maximum size of		 32
                         filehandle cache.
 Status  : Public

=cut

sub new {
  my $class = shift;
  my $self = $class->SUPER::new(@_);
  @{$self}{qw(bdb_directory bdb_write_flag bdb_verbose bdb_maxopen bdb_outfile bdb_format)} =
      @_ == 1 ? (shift,0,0)
              : $self->_rearrange([qw(DIRECTORY WRITE_FLAG VERBOSE MAXOPEN OUT FORMAT)],@_);
  # we delay processing the configuration file since we might want to create it.
  $self->{bdb_maxopen} ||= 32;
  $self->primary_namespace($self->default_primary_namespace);
  $self->secondary_namespaces($self->default_secondary_namespaces);
  $self->file_format($self->default_file_format) unless defined $self->{bdb_format};
  $self->_read_config() if -e $self->_config_path;
  $self;
}

# return a filehandle seeked to the appropriate place
# this only works with the primary namespace
sub _get_stream {
  my ($self,$id) = @_;
  my ($filepath,$offset,$length) = $self->_lookup_primary($id)
    or $self->throw("Unable to find a record for $id in the flat file index");
  my $fh = $self->_fhcache($filepath)
    or $self->throw("couldn't open $filepath: $!");
  seek($fh,$offset,0) or $self->throw("can't seek on $filepath: $!");
  $fh;
}

# return records corresponding to the indicated index
# if there are multiple hits will return a list in list context,
# otherwise will throw an exception
sub fetch_raw {
  my ($self,$id,$namespace) = @_;

  # secondary lookup
  if (defined $namespace && $namespace ne $self->primary_namespace) { 
    my @hits = $self->_lookup_secondary($namespace,$id);
    $self->throw("Multiple records correspond to $namespace=>$id but function called in a scalar context")
      unless wantarray;
    return map {$self->_read_record(@$_)} @hits;
  }

  # primary lookup
  my @args = $self->_lookup_primary($id)
    or $self->throw("Unable to find a record for $id in the flat file index");
  return $self->_read_record(@args);
}

# create real live Bio::Seq object
sub get_Seq_by_id {
  my $self = shift;
  my $id   = shift;
  my $fh   = eval {$self->_get_stream($id)} or return;
  my $seqio = Bio::SeqIO->new( -Format => $self->file_format,
			       -fh     => $fh);
  $seqio->next_seq;
}

=head2 fetch

  Title   : fetch
  Usage   : $index->fetch( $id )
  Function: Returns a Bio::Seq object from the index
  Example : $seq = $index->fetch( 'dJ67B12' )
  Returns : Bio::Seq object
  Args    : ID

Deprecated.  Use get_Seq_by_id instead.

=cut

*fetch = \&get_Seq_by_id;

# fetch array of Bio::Seq objects
sub get_Seq_by_acc {
  my $self = shift;
  return $self->get_Seq_by_id(shift) if @_ == 1;
  my ($ns,$key) = @_;
  my @primary_ids = $self->expand_ids($ns => $key);
  $self->throw("more than one sequences correspond to this accession")
    if @primary_ids > 1 && !wantarray;
  return map {$self->get_Seq_by_id($_)} @primary_ids;
}

=head2 get_PrimarySeq_stream

 Title   : get_PrimarySeq_stream
 Usage   : $stream = get_PrimarySeq_stream
 Function: Makes a Bio::DB::SeqStreamI compliant object
           which provides a single method, next_primary_seq
 Returns : Bio::DB::SeqStreamI
 Args    : none


=cut

sub get_PrimarySeq_stream {
  my $self = shift;
  my @files  = $self->_files || 0;
  my $out = Bio::SeqIO::MultiFile->new( -format => $self->file_format ,
					-files  => \@files);
  return $out;
}

sub get_all_primary_ids {
  my $self = shift;
  my $db   = $self->primary_db;
  return keys %$db;
}

=head2 get_all_primary_ids

 Title   : get_all_primary_ids
 Usage   : @ids = $seqdb->get_all_primary_ids()
 Function: gives an array of all the primary_ids of the
           sequence objects in the database.
 Example :
 Returns : an array of strings
 Args    : none

=cut

# this will perform an ID lookup on a (possibly secondary)
# id, returning all the corresponding ids
sub expand_ids {
  my $self = shift;
  my ($ns,$key) = @_;
  return $key unless defined $ns;
  return $key if $ns eq $self->primary_namespace;
  my $db   = $self->secondary_db($ns)
    or $self->throw("invalid secondary namespace $ns");
  my $record = $db->{$key} or return;  # nothing there
  return $self->unpack_secondary($record);
}

sub write_seq {
  my $self = shift;
  my $seq  = shift;
  my $fh   = $self->out_file or $self->throw('no outfile defined; use the -out argument to new()');
  
}

# build index from files listed
sub build_index {
  my $self  = shift;
  my @files = @_;
  my $count = 0;
  for my $file (@files) {
    $count++ if $self->_index_file($file);
  }
  $self->write_config;
  $count;
}

sub _index_file {
  my $self = shift;
  my $file = shift;

  my $fileno = $self->_path2fileno($file);
  defined $fileno or $self->throw("could not create a file number for $file");

  my $fh     = $self->_fhcache($file) or $self->throw("could not open $file for indexing: $!");
  my $offset = 0;
  while (!eof($fh)) {
    my ($ids,$adjustment)  = $self->parse_one_record($fh);
    $adjustment ||= 0;  # prevent uninit variable warning
    my $pos = tell($fh) + $adjustment;
    $self->_store_index($ids,$file,$offset,$pos-$offset);
    $offset = $pos;
  }
  1;
}

# return the file format
sub file_format {
  my $self = shift;
  my $d    = $self->{bdb_format};
  $self->{bdb_format} = shift if @_;
  $d;
}

=head2 To Be Implemented in Subclasses

The following methods MUST be implemented by subclasses.

=cut

# This is the method that must be implemented in
# child classes.  It is passed a filehandle which should
# point to the next record to be indexed in the file, 
# and returns a two element list
# consisting of a key and an adjustment value.
# The key can be a scalar, in which case it is treated
# as the primary ID, or a hashref containing namespace=>[id] pairs,
# one of which MUST correspond to the primary namespace.
# The adjustment value is normally zero, but can be a positive or
# negative integer which will be added to the current file position
# in order to calculate the correct end of the record.
sub parse_one_record {
  my $self = shift;
  my $fh   = shift;
  $self->throw_not_implemented;
  # here's what you would implement
  my (%keys,$offset);
  return (\%keys,$offset);
}

sub default_file_format {
  my $self = shift;
  $self->throw_not_implemented;
}

=head2 May Be Overridden in Subclasses

The following methods MAY be overridden by subclasses.

=cut

sub default_primary_namespace {
  return "ACC";
}

sub default_secondary_namespaces {
  return ();
}

sub _read_record {
  my $self = shift;
  my ($filepath,$offset,$length) = @_;
  my $fh = $self->_fhcache($filepath)
    or $self->throw("couldn't open $filepath: $!");
  seek($fh,$offset,0) or $self->throw("can't seek on $filepath: $!");
  my $record;
  read($fh,$record,$length) or $self->throw("can't read $filepath: $!");
  $record
}

# accessors
sub directory {
  my $self = shift;
  my $d = $self->{bdb_directory};
  $self->{bdb_directory} = shift if @_;
  $d;
}
sub write_flag {
  my $self = shift;
  my $d = $self->{bdb_write_flag};
  $self->{bdb_write_flag} = shift if @_;
  $d;
}
sub verbose {
  my $self = shift;
  my $d = $self->{bdb_verbose};
  $self->{bdb_verbose} = shift if @_;
  $d;
}
sub out_file {
  my $self = shift;
  my $d = $self->{bdb_outfile};
  $self->{bdb_outfile} = shift if @_;
  $d;
}

# return a list in the form ($filepath,$offset,$length)
sub _lookup_primary {
  my $self    = shift;
  my $primary = shift;
  my $db     = $self->primary_db
    or $self->throw("no primary namespace database is open");

  my $record = $db->{$primary} or return;  # nothing here

  my($fileid,$offset,$length) = $self->unpack_primary($record);
  my $filepath = $self->_fileno2path($fileid)
    or $self->throw("no file path entry for fileid $fileid");
  return ($filepath,$offset,$length);
}

# return a list of array refs in the form [$filepath,$offset,$length]
sub _lookup_secondary {
  my $self = shift;
  my ($namespace,$secondary) = @_;
  my @primary = $self->expand_ids($namespace=>$secondary);
  return map {[$self->_lookup_primary($_)]} @primary;
}

# store indexing information into a primary & secondary record
# $namespaces is one of:
#     1. a scalar corresponding to the primary name
#     2. a hashref corresponding to namespace=>id identifiers
#              it is valid for secondary id to be an arrayref
sub _store_index {
  my $self = shift;
  my ($keys,$filepath,$offset,$length) = @_;
  my ($primary,%secondary);

  if (ref $keys eq 'HASH') {
    my %valid_secondary = map {$_=>1} $self->secondary_namespaces;
    while (my($ns,$value) = each %$keys) {
      if ($ns eq $self->primary_namespace) {
	$primary = $value;
      } else {
	$valid_secondary{$ns} or $self->throw("invalid secondary namespace $ns");
	push @{$secondary{$ns}},$value;
      }
    }
    $primary or $self->throw("no primary namespace ID provided");
  } else {
    $primary = $keys;
  }

  $self->throw("invalid primary ID; must be a scalar") 
    if ref($primary) =~ /^(ARRAY|HASH)$/;  # but allow stringified objects

  $self->_store_primary($primary,$filepath,$offset,$length);
  for my $ns (keys %secondary) {
    my @ids = ref $secondary{$ns} ? @{$secondary{$ns}} : $secondary{$ns};
    $self->_store_secondary($ns,$_,$primary) foreach @ids;
  }

  1;
}

# store primary index
sub _store_primary {
  my $self = shift;
  my ($id,$filepath,$offset,$length) = @_;

  my $db = $self->primary_db
    or $self->throw("no primary namespace database is open");
  my $fileno = $self->_path2fileno($filepath);
  defined $fileno or $self->throw("could not create a file number for $filepath");

  my $record = $self->pack_primary($fileno,$offset,$length);
  $db->{$id} = $record or return;  # nothing here
  1;
}

# store a primary index name under a secondary index
sub _store_secondary {
  my $self = shift;
  my ($secondary_ns,$secondary_id,$primary_id) = @_;

  my $db   = $self->secondary_db($secondary_ns)
    or $self->throw("invalid secondary namespace $secondary_ns");

  # first get whatever secondary ids are already stored there
  my @primary = $self->unpack_secondary($db->{$secondary_id});
  # uniqueify
  my %unique  = map {$_=>undef} @primary,$primary_id;

  my $record = $self->pack_secondary(keys %unique);
  $db->{$secondary_id} = $record;
}

# get output file handle
sub _outfh {
  my $self = shift;
#### XXXXX FINISH #####
#  my $
}

# unpack a primary record into fileid,offset,length
sub unpack_primary {
  my $self = shift;
  my $index_record = shift;
  return split "\t",$index_record;
}

# unpack a secondary record into a list of primary ids
sub unpack_secondary {
  my $self = shift;
  my $index_record = shift or return;
  return split "\t",$index_record;
}

# pack a list of fileid,offset,length into a primary id record
sub pack_primary {
  my $self = shift;
  my ($fileid,$offset,$length) = @_;
  return join "\t",($fileid,$offset,$length);
}

# pack a list of primary ids into a secondary id record
sub pack_secondary {
  my $self = shift;
  my @secondaries = @_;
  return join "\t",@secondaries;
}

# read the configuration file
sub _read_config {
  my $self = shift;
  my $path = $self->_config_path;
  open (F,$path) or $self->throw("open error on $path: $!");
  my %config;
  while (<F>) {
    chomp;
    my ($tag,@values) = split "\t";
    $config{$tag} = \@values;
  }
  close F or $self->throw("close error on $path: $!");

  $config{index}[0] eq 'BerkeleyDB/1'
    or $self->throw("invalid configuration file $path: no index line");

  # set up primary namespace
  my $primary_namespace = $config{primary_namespace}[0]
    or $self->throw("invalid configuration file $path: no primary namespace defined");
  $self->primary_namespace($primary_namespace);

  # set up secondary namespaces (may be empty)
  $self->secondary_namespaces($config{secondary_namespaces});

  # get file paths and their normalization information
  my @normalized_files = grep {$_ ne ''} map {/^fileid_(\S+)/ && $1} keys %config;
  for my $nf (@normalized_files) {
    my ($file_path,$file_length) = @{$config{"fileid_${nf}"}};
    $self->add_flat_file($file_path,$file_length,$nf);
  }
  1;
}

sub add_flat_file {
  my $self = shift;
  my ($file_path,$file_length,$nf) = @_;

  # check that file_path is absolute
  File::Spec->file_name_is_absolute($file_path)
      or $self->throw("the flat file path $file_path must be absolute");

  -r $file_path or $self->throw("flat file $file_path cannot be read: $!");

  my $current_size = -s _;
  if (defined $file_length) {
    $current_size == $file_length
      or $self->throw("flat file $file_path has changed size.  Was $file_length bytes; now $current_size");
  } else {
    $file_length = $current_size;
  }

  unless (defined $nf) {
    $self->{bdb__file_index} = 0 unless exists $self->{bdb__file_index};
    $nf = $self->{bdb__file_index}++;
  }
  $self->{bdb__flat_file_path}{$nf}      = $file_path;
  $self->{bdb__flat_file_no}{$file_path} = $nf;
  $self->{bdb__flat_file_length}{$nf}    = $file_length;
  $nf;
}

sub _path2fileno {
  my $self = shift;
  my $path = shift;
  return $self->add_flat_file($path)
    unless exists $self->{bdb__flat_file_no}{$path};
  $self->{bdb__flat_file_no}{$path};
}

sub _fileno2path {
  my $self = shift;
  my $fileno = shift;
  $self->{bdb__flat_file_path}{$fileno};
}

sub _files {
  my $self = shift;
  my $paths = $self->{bdb__flat_file_no};
  return keys %$paths;
}

sub write_config {
  my $self = shift;
  $self->write_flag or $self->throw("cannot write configuration file because write_flag is not set");
  my $path = $self->_config_path;

  open (F,">$path") or $self->throw("open error on $path: $!");

  print F "index\tBerkeleyDB/1\n";
  $self->{bdb__flat_file_path} or $self->throw("cannot write config file because no flat files defined");
  for my $nf (keys %{$self->{bdb__flat_file_path}}) {
    my $path = $self->{bdb__flat_file_path}{$nf};
    my $size = $self->{bdb__flat_file_length}{$nf};
    print F join("\t","fileid_$nf",$path,$size),"\n";
  }

  # write primary namespace
  my $primary_ns = $self->primary_namespace
    or $self->throw('cannot write config file because no primary namespace defined');

  print F join("\t",'primary_namespace',$primary_ns),"\n";

  # write secondary namespaces
  my @secondary = $self->secondary_namespaces;
  print F join("\t",'secondary_namespaces',@secondary),"\n";

  close F or $self->throw("close error on $path: $!");
}

sub primary_namespace {
  my $self = shift;
  my $d    = $self->{bdb_primary_namespace};
  $self->{bdb_primary_namespace} = shift if @_;
  $d;
}

# get/set secondary namespace(s)
# pass an array ref.
# get an array ref in scalar context, list in list context.
sub secondary_namespaces {
  my $self = shift;
  my $d    = $self->{bdb_secondary_namespaces};
  $self->{bdb_secondary_namespaces} = (ref($_[0]) eq 'ARRAY' ? shift : \@_) if @_;
  $d = [$d] unless ref($d) eq 'ARRAY';  # just paranoia
  return wantarray ? @$d : $d;
}

sub primary_db {
  my $self = shift;
  # lazy opening
  $self->_open_bdb unless exists $self->{bdb_primary_db};
  return $self->{bdb_primary_db};
}

sub secondary_db {
  my $self = shift;
  my $secondary_namespace = shift
    or $self->throw("usage: secondary_db(\$secondary_namespace)");
  $self->_open_bdb unless exists $self->{bdb_primary_db};
  return $self->{bdb_secondary_db}{$secondary_namespace};
}

sub _open_bdb {
  my $self = shift;

  my $flags = $self->write_flag ? O_CREAT|O_RDWR : O_RDONLY;

  my $primary_db = {};
  tie(%$primary_db,'DB_File',$self->_catfile($self->_primary_db_name),$flags,0666,$DB_BTREE)
    or $self->throw("Could not open primary index file");
  $self->{bdb_primary_db} = $primary_db;

  for my $secondary ($self->secondary_namespaces) {
    my $secondary_db = {};
    tie(%$secondary_db,'DB_File',$self->_catfile($self->_secondary_db_name($secondary)),$flags,0666,$DB_BTREE)
      or $self->throw("Could not open primary index file");
    $self->{bdb_secondary_db}{$secondary} = $secondary_db;
  }

  1;
}

sub _primary_db_name {
  my $self = shift;
  my $pns  = $self->primary_namespace or $self->throw('no primary namespace defined');
  return "key_$pns";
}

sub _secondary_db_name {
  my $self  = shift;
  my $sns   = shift;
  return "id_$sns";
}

sub _config_path {
  my $self = shift;
  $self->_catfile($self->_config_name);
}

sub _catfile {
  my $self = shift;
  my $component = shift;
  Bio::Root::IO->catfile($self->directory,$component);
}

sub _config_name { CONFIG_FILE_NAME }

sub _fhcache {
  my $self  = shift;
  my $path  = shift;
  my $write = shift;

  if (!$self->{bdb_fhcache}{$path}) {
    $self->{bdb_curopen} ||= 0;
    if ($self->{bdb_curopen} >= $self->{bdb_maxopen}) {
      my @lru = sort {$self->{bdb_cacheseq}{$a} <=> $self->{bdb_cacheseq}{$b};} keys %{$self->{bdb_fhcache}};
      splice(@lru, $self->{bdb_maxopen} / 3);
      $self->{bdb_curopen} -= @lru;
      for (@lru) { delete $self->{bdb_fhcache}{$_} }
    }
    if ($write) {
      my $modifier = $self->{bdb_fhcache_seenit}{$path}++ ? '>' : '>>';
      $self->{bdb_fhcache}{$path} = IO::File->new("${modifier}${path}") or return;
    } else {
      $self->{bdb_fhcache}{$path} = IO::File->new($path) or return;
    }
    $self->{bdb_curopen}++;
  }
  $self->{bdb_cacheseq}{$path}++;
  $self->{bdb_fhcache}{$path}
}

1;
