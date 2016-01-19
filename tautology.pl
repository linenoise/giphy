#!/usr/bin/perl -w
use strict;
use OPC;

my $board_width = 16;
my $board_height = 16;

### Connect to the OPC server
my $client = new OPC('localhost:7890');
$client->can_connect();

### Construct an empty frame
sub empty_frame {
	my $frame = [];
	foreach my $x (0..$board_width-1){
		my $line = [];
		foreach my $y (0..$board_height-1){
			push $line, [0,0,0];
		}
		push $frame, $line;
	}
	return $frame;
}

### Construct a frame for the Tautology logo
my $tautology_frame = empty_frame();
my $pen_color = [70,70,75];

### Downstroke
foreach my $x (11..12){
	foreach my $y (2..13){
		$tautology_frame->[$y]->[$x] = $pen_color;
	}
}

### Sidestrokes
foreach my $x (3..12){
	foreach my $y (5..6){
		$tautology_frame->[$y]->[$x] = $pen_color;
	}
	foreach my $y (9..10){
		$tautology_frame->[$y]->[$x] = $pen_color;
	}
}

### Push a frame to the lightboard
sub push_frame{
	my ($frame) = @_;
	
	my $pixels = [];
	my $line_number = 0;
	foreach my $line (@$frame){
		if ($line_number % 2 == 0) {
			my @line = reverse(@$line);
			$line = \@line;
		}
		foreach my $pixel (@$line){
			push @$pixels, $pixel;
		}
		$line_number++;
	}
	$client->put_pixels(0,$pixels);
}

push_frame(empty_frame());
push_frame($tautology_frame);

