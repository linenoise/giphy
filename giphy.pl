#!/usr/bin/perl -w
use strict;
use Imager;
use OPC;
use Storable;
use Time::HiRes qw/usleep/;

$|=1; 
my $board_width = 16;
my $board_height = 16;
my $max_brightnexx = 128;

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
	usleep 50000;
}

### Read a GIF file from the drive
sub read_gif_file{
	my ($filename) = @_;
	my @gif = Imager->read_multi(file=>$filename) or die Imager->errstr;
	return \@gif;
}

### Load all relevant gif files
sub load_gif_files{
	my $files = {};
	
	### If there are image(s) on the command line, only display those.
	foreach my $filename (@ARGV){
		$files->{$filename} = {
			'data' => read_gif_file($filename)
		};
	}

	### Otherwise, just display whatever is in the ./gifs directory
	unless(scalar(%$files)){
		opendir (DIR, 'gifs') or die $!;
		while (my $filename = readdir(DIR)) {
			next if $filename =~ /^\./;
			$files->{$filename} = {
				'data' => read_gif_file("gifs/$filename")
			};
		}
	}

	return $files;
}

sub presample_file {
	my ($filename,$files) = @_;
	my $file = $files->{$filename}->{'data'};
	
	my @frames;
	my $cache_file = "cache/$filename.storable";
	if (-f $cache_file){
		my $frames = retrieve($cache_file);
		@frames = @$frames;
	} else {
		foreach my $gif_frame (@$file){
			my $board_frame = empty_frame();
			my $image_width = $gif_frame->getwidth();
			my $image_height = $gif_frame->getheight();

			### If it's not square, square it.
			if($image_height > $image_width){
				$image_height = $image_width;		
			}
			if($image_width > $image_height){
				$image_width = $image_height;		
			}

			foreach my $x (0..$board_width-1){
				foreach my $y (0..$board_height-1){

					# Map each board pixel to a 2x2 matrix of related image pixels
					my $x_step = int($image_width / $board_width);
					my $y_step = int($image_height / $board_height);
					my ($red,$green,$blue,$alpha) = (0,0,0,0);

					# 2. Average the values of all pixels in that bounding box.
					#    A. Divide that by four. That's padding_value

					my $x0 = $x * $x_step;
					my $y0 = $y * $y_step;
					my $x1 = ($x+1) * $x_step;
					my $y1 = ($y+1) * $y_step;
					my ($padding_red, $padding_green,$padding_blue) =
					   downsample_region($gif_frame,$x0,$y0,$x1,$y1);
					($red, $green, $blue) = (
						$red + ($padding_red / 4),
						$green + ($padding_green / 4),
						$blue + ($padding_blue / 4)
					);

					# 3. Average the values of the centermost 50% of pixels
					#    A. Divide that by four. That's margin_value

					$x0 = $x * $x_step + int($x_step / 2);
					$y0 = $y * $y_step + int($y_step / 2);
					$x1 = ($x+1) * $x_step - int($x_step / 2);
					$y1 = ($y+1) * $y_step - int($x_step / 2);
					my ($margin_red, $margin_green,$margin_blue) =
					  downsample_region($gif_frame,$x0,$y0,$x1,$y1);
					($red, $green, $blue) = (
						$red + ($margin_red / 4),
						$green + ($margin_green / 4),
						$blue + ($margin_blue / 4)
					);

					# 4. Average the values of the centermost pixel
					#    A. Divide that by two. That's inner_value

					my $pixel = $gif_frame->getpixel(y=>$x * $x_step,x=>$y * $y_step);
					if($pixel){
						my ($red_sample, $green_sample, $blue_sample) = $pixel->rgba();
						($red, $green, $blue) = (
							$red + ($red_sample / 2),
							$green + ($green_sample / 2),
							$blue + ($green_sample / 2)
						);
					}

					# 5. Add padding_value, margin_value, and inner_value.
					#    A. That's pixel_value
					###

					$board_frame->[$x]->[$y] = [$red / 2,$green / 2,$blue / 2];
				}
			}
			push @frames, $board_frame;
		}
		store \@frames, $cache_file;
	}
    $files->{$filename}->{'frames'} = \@frames;
}

sub downsample_region {
	my ($gif_frame,$x0,$y0,$x1,$y1) = @_;
	my ($red_average, $green_average,$blue_average) = (0.0,0.0,0.0);
	my ($red_sample, $green_sample,$blue_sample) = (0,0,0);

	my $sample_size = 0;
	my @x_samples = ($x0..$x1);
	my @y_samples = ($y0..$y1);
	
	foreach my $pixel ($gif_frame->getpixel(y=>\@x_samples,x=>\@y_samples)){
		if($pixel){
			my ($red_sample, $green_sample,$blue_sample) = $pixel->rgba();
			$red_average += $red_sample;
			$green_average += $green_sample;
			$blue_average += $blue_sample;
			$sample_size++;
		}
	}
	if ($sample_size){
		$red_average = int($red_average / $sample_size);
		$green_average = int($green_average / $sample_size);
		$blue_average = int($blue_average / $sample_size);

		return ($red_average, $green_average, $blue_average);
	} else {
		return (0,0,0);
	}
}

sub pretrack_file {
	my ($filename,$files) = @_;
	my $frames = $files->{$filename}->{'frames'};

	my $cursor = 0;
	my @track;
	while(scalar(@track) < 125){
		push @track, $files->{$filename}->{'frames'}->[$cursor];
		$cursor++;
		if($cursor > scalar(@{$files->{$filename}->{'frames'}})-1){
			$cursor = 0;
		}
	}
	
	$files->{$filename}->{'track'} = \@track;
}

sub composite_frame{
	my ($frame_a, $scalar_a, $frame_b, $scalar_b) = @_;
	my $frame = empty_frame();

	my ($a, $b);
	foreach my $x (0..$board_width-1){
		foreach my $y (0..$board_height-1){
			foreach my $z (0..2) {
				$a = ($frame_a->[$x]->[$y]->[$z] * $scalar_a) / 100;
				$b = ($frame_b->[$x]->[$y]->[$z] * $scalar_b) / 100;
				$frame->[$x]->[$y]->[$z] = $a;
				$frame->[$x]->[$y]->[$z] = $b if $b > $a;
			}
		}
	}
	return $frame;
}

### Main working loop
sub loop {
	my ($files) = @_;

	### Presample and cache all GIFs to be played
	my @filenames;
	print "Presampling GIFs...\n";
	foreach my $filename (keys %$files){
		presample_file($filename, $files);
		my $frame_count = scalar(@{$files->{$filename}->{'frames'}});
		print "   * $filename: $frame_count frames\n";
		push @filenames, $filename;
	}
	
	### Pre-track all GIFs to be played.
	print "Pretracking GIFs...\n";
	foreach my $filename (keys %$files){
		pretrack_file($filename, $files);
		my $track_frame_count = scalar(@{$files->{$filename}->{'track'}});
		print "   * $filename: $track_frame_count frames\n";
	}

	### Initialize the display
	push_frame(empty_frame());

	### Display the GIFs
	print "Displaying GIFs...\n";
	my $current_filename = @filenames[int(rand(scalar(@filenames)))];
	my $current_track = $files->{$current_filename}->{'track'};
	my $previous_track;
	my $previous_filename;
	while(1){
		### 0..24: Fade-in frames 0..24 of this track + Play frames 50..74 of previous track
		foreach my $index (0..24){
			my $frame;
			my $current_track_frame = $current_track->[$index];
			my $previous_track_frame;
			if ($previous_track){
				$previous_track_frame = $previous_track->[$index+75];
			} else {
				$previous_track_frame = empty_frame();
			}
			my $display_frame = composite_frame(
				$current_track_frame, ($index+1) * 4,
				$previous_track_frame, 100
			);
			push_frame($display_frame);
		}

		### 25..49: Play frames 25..50 of this track + Fade-out frames 75..99 of previous track
		foreach my $index (25..49){
			my $frame;
			my $current_track_frame = $current_track->[$index];
			my $previous_track_frame;
			if ($previous_track){
				$previous_track_frame = $previous_track->[$index+75];
			} else {
				$previous_track_frame = empty_frame();
			}
			my $display_frame = composite_frame(
				$current_track_frame, 100,
				$previous_track_frame, (25-($index-25)) * 4
			);
			push_frame($display_frame);
		}

		### 50..74: Solo just this track
		foreach my $index (50..74){
			push_frame($current_track->[$index]);
		}

		### 75 Previous = Current, Current = pick something new.
		$previous_track = $current_track;
		$previous_filename = $current_filename;
		while($current_filename eq $previous_filename){
			$current_filename = @filenames[int(rand(scalar(@filenames)))];
		}
		$current_track = $files->{$current_filename}->{'track'};
	}
}

### Load all relevant gif files from the drive
my $files = load_gif_files();
unless(scalar(%$files)){
	die "No GIF files found in ./gifs or specified by command arguments."
}

### Display all files in order
loop($files);
