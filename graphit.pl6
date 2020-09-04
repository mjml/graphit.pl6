#!/bin/perl6
use v6;
#use Grammar::Tracer;

my %crafting_speed = %( "assembling-machine-1" => 0.5,
												"assembling-machine-2" => 0.75,
												"assembling-machine-3" => 1.25,
												"stone-furnace"      => 1,
												"steel-furnace"      => 2,
												"electric-furnace"   => 2,
												"oil-refinery"       => 1,
											  "chemical-plant"     => 1);

grammar RecipeFile {

	rule TOP { <.ws> 'data' ':' 'extend' [ <outer1> | <factorio-defs> ] <.ws> }
	rule outer1 { '(' <factorio-defs> ')' }
	rule factorio-defs { '{' <factorio-def>* %% ',' '}' }
	rule factorio-def { '{' <kv>+ %% ',' '}' }
  rule kv { <symb> '=' <rvalue-any> }
	token symb {<alpha><alnum>*}
	rule rvalue-any { <literal> | <table> }
	rule table { '{' <table-entry>* %% ',' '}' }
	rule table-entry { <kv> | <literal> | <table> }
	rule literal { <quoted> | <number> | <boolean> }
	token quoted {	\x22<-[\x22]>*\x22 }
	token number { <digit>+[\.<digit>+]? }
	token boolean { 'true' | 'false' }
}

class RecipeActions
{
	method TOP($/) { $/.make: ($<factorio-defs> // $<outer1>).made; }
	method outer1($/) { $/.make( $<factorio-defs>.made ) }
	method factorio-defs($/) { $/.make: %( $<factorio-def>>>.made ); }
	method factorio-def($/) {
		my %h = Hash.new( $/<kv>>>.made );
		$/.make(%h{'name'} => %h);
		say %h{'name'};
	}
	method kv($/) {
		my $kv = $<symb>.made => $<rvalue-any>.made;
		$/.make: $kv;
	};
	method symb($/) { $/.make: $<alpha>.Str ~ ([~] $<alnum>».Str) }
	method rvalue-any($/) { $/.make: ($<literal> // $<table>).made }
	method table($/) {
		my %h;
		my Int $i = 0;
		for $<table-entry>>>.made -> $e {
			given $e {
				when Pair { %h{$e.key} = $e.value }
				when Any  { %h{$i} = $e }
			}
			$i++;
		}
		$/.make(%h);
	}
	method table-entry($/) { $/.make: ($<kv> // $<literal> // $<table>).made  }
	method literal($/) { $/.make: ($<quoted> // $<number> // $<boolean>).made }
	method quoted($/) {
		my $len = $/.Str.chars;
		my $s = $/.Str.substr(1,$len-2);
		$/.make($s)
	}
	method number($/) {  $/.make: Num($/.Str); }
	method boolean($/) {  $/.make: Bool($/.Str); }
	method boolean-literal($/) { $/.Str eq "true" }
	
};

class BuildNode {
	has Str $.name;
	has Str $.assembler_type;
	has Int $.factories is rw = 0;
	has Num $.output_rate is rw = 0.Num;
	has %.requirements is rw = @;
	submethod new( Str $name, Str $assembler_type = "s") {
		return self.bless( :$name, :$assembler_type );
	}
}

grammar Schema {
  rule TOP { <.ws> 'schema' '{' <produce-stmt>* <exclude-stmt>* '}' }
	rule produce-stmt { 'produce' <rate>?  <identifier> <using-clause>? }
	token rate { <number> \/ <unit> }
	token number { <digit>+ [\.<digit>+]? }
	token identifier { <alpha>[<[\-]>|<alnum>]* }
	rule using-clause { 'using' <identifier> }
	rule exclude-stmt { 'exclude' <regex>+ % ',' }
	rule regex {"\x22" <-[\x22]>* "\x22"}
	token unit {s|m|h}
}

class SchemaParser
{
	method identifier($/) { $/.make: $/.Str }
	method rate($/) { $/.make: $<unit>.made eq "h" ?? $<number>.made / 3600 !! $<unit>.made eq "m" ?? $<number>.made / 60 !! $<number>.made }
	method number($/) { $/.make: $/.Str.Num }
	method unit($/) { $/.make: $/.Str }
	method regex($/) { $/.make: $/.Str.subst(1,$/.Str.chars-2) }
	method exclude-stmt($/) { $/.make: $<regex>>>.made }
	method using-clause($/) { $/.make: $<identifier>.made }
	method produce-stmt($/) {
		my BuildNode $node;
		my Str $asm;
		if ($<using-clause>) { $asm = $<using-clause>.made}
		else { $asm = "assembling-machine-1"}
		$node = BuildNode.new($<identifier>.made, $asm);
		if ($<rate>) { $node.output_rate = $<rate>.made }
		my %h = %( $node.name => $node );
		$/.make: %h;
	}
	method TOP($/) {
		my %h = $<produce-stmt>>>.made.reduce( sub (Hash $c, Hash $d) { return $c.append: $d.kv } );
		my @e = $<exclude-stmt>>>.made>>.List.flat;
		$/.make({ "produce" => %h, "exclude" => @e });
	}
}

subset Dir of Str where .IO.d;
subset FileName of Str where .IO.f;

my %recipes = %();
my %plan = %();
my @queue = ();

sub compute_structure(BuildNode:D $node, Num $more)
{
	# compute required number of assemblers
	%recipes{$node.name} or return;
	
	my %r := %recipes{$node.name};
	my $crafting_speed = %crafting_speed{$node.assembler_type};
	my $energy_required = %r{"energy_required"} // %r{"normal"}{"energy_required"} // 0.5;
	my $products = %recipes{$node.name}{"result_count"} || 1;

	$node.factories = ceiling($node.output_rate * $energy_required / $crafting_speed / $products);
	say sprintf("\n*** %s: f = ceil(o * e / s / p) = ceil(%4f * %4f / %4f / %4f) = %f",
							$node.name, $node.output_rate , $energy_required , $crafting_speed , $products, $node.factories);
	
	%plan{$node.name} := $node;

	my %ingredients = %();
	if (%r{'normal'}:exists) {
		say "Difficulty-selected recipe ingredients";
		%ingredients = %r{'normal'}{'ingredients'};
		say %ingredients.gist;
  } elsif (%r{'ingredients'}:exists) {
		say "Simplified recipe ingredients";
		%ingredients =  %r{'ingredients'};
		say %ingredients.gist;
	} else {
		warn "Couldn't find ingredients for " ~ $node.name and return;
	}

	%ingredients = %ingredients.values.map: {
		when .<0>:exists { $_<0> => ($_<1>, 'item') }
		when .<type>:exists { $_<name> => ($_<amount>, $_<type>) }
	}

	
	my @new_nodes = %ingredients.kv.map(
		sub ($ingredient, ($quantity, $type)) {
			my $asm =
			!%recipes{$ingredient}                              ?? '' !!
			%plan{"produce"}{$ingredient}                       ?? %plan{"produce"}{$ingredient}.assembler_type !! 
			%recipes{$ingredient}<category> eq 'smelting'       ?? 'stone-furnace' !!
			%recipes{$ingredient}<category> eq 'chemistry'      ?? 'chemical-plant' !!
			%recipes{$ingredient}<category> eq 'oil-processing' ?? 'oil-refinery' !! $node.assembler_type;
			my BuildNode $cnode;
			if (%plan{'produce'}{$ingredient}:exists) {
				$cnode := %plan{'produce'}{$ingredient}
			} else {
				$cnode := %plan{'produce'}{$ingredient} := BuildNode.new($ingredient, $asm);
			}
			say sprintf("Adding %ix%i to %s due to %s", $more, $quantity, $cnode.name, $node.name);
			$cnode.output_rate += $more * $quantity;
			compute_structure($cnode, $more * $quantity);
			return $cnode;
		});
	$node.requirements = %ingredients;
}

sub MAIN(FileName $schemafile, Dir :d(:$basedir) = $*CWD.path, Bool :t(:$testmode) = False)
{	
	say "Parsing in $basedir...";
	my @files;
	@files = ($basedir.Str ~ "/data/base/prototypes/recipe").IO.dir(test => {!.IO.d} );
	say @files.elems ~ " files found.";
	if ($testmode) { @files = ( $basedir.Str ~ "/data/base/prototypes/recipe/circuit-network.lua".IO )	}
	for @files -> $file {
		my $text = $file.path.IO.slurp();
		$text ~~ s:g/\-\-.*?$$//;
		say "Parsing " ~ $file.path;
		my %h = RecipeFile.parse($text, actions=>RecipeActions.new).made;
		%recipes{%h.keys} = %h.values;
	}
	
	say "\nFound " ~ %recipes.elems ~ ":";
	say %recipes.keys;
	
	say "\nReading Schema $schemafile";
	my $schema = $schemafile.IO.slurp();
	%plan = Schema.parse($schema, actions => SchemaParser.new).made;
	%plan{'produce'}.values.map( { compute_structure($_, $_.output_rate) } );	
	%plan{"produce"}.values.map({ say $_; });

	say "\n";
	my @nodes = %plan{'produce'}.values;
	my @dotnodes = @nodes.map: -> BuildNode $node {
		# minor hack: don't show factory type or number if there are no ingredients (ie: basic ores, oil, etc)
		my Str $fdesc = ($node.requirements.elems > 0) ?? "using %i of %s".sprintf($node.factories, $node.assembler_type) !! "";
		sprintf("\"%s\" [ width=%f, height=%f, label=\"%s\noutput_rate=%.3g/s\n%s\" fontsize=\"10\" shape=\"rect\" ]\n\n",
						$node.name, sqrt((3 * $node.factories + 1)/5), 0.8, $node.name, $node.output_rate, $fdesc)
	};
	my @dotedges = @nodes.map: -> BuildNode $n {
		my @ll = $n.requirements.kv.map(
			sub ($ingredient, ($quantity, $type)) {
				my $label = ($type eq 'fluid') ?? $quantity ~ "(fluid)" !! $quantity;
				sprintf("\"%s\" -> \"%s\" [fontsize=9, label=\"%s\"]\n\n", $ingredient, $n.name, $label);
			});
	}

	my ($dotfile, $svgfile, $pngfile);
	
	given $schemafile {
		$dotfile = S/\.fsch$/\.dot/;
		$svgfile = S/\.fsch/\.svg/;
		$pngfile = S/\.fsch/\.png/
	}
	
	my $dottext = sprintf("digraph \{\n%s\n%s\}\n", ([~] @dotnodes), ([~] @dotedges));
	say $dottext;
	$dotfile.IO.spurt($dottext);
	say "\n$dotfile";	
	qqx{ dot -Tsvg $dotfile > $svgfile  };
	say $svgfile;
	qqx{ convert $svgfile -size 1024x960 $pngfile };
	say $pngfile;
	qqx{ chrome $pngfile };
	qqx{ rm -rf $svgfile $dotfile }
}
