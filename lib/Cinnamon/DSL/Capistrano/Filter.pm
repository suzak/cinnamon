package Cinnamon::DSL::Capistrano::Filter;
use strict;
use warnings;
no warnings 'redefine';
use Filter::Simple;

FILTER_ONLY
    code => sub {
        s/:(\w+)/'$1'/g;
        s/\bdo\b/, sub {/g;
        s/\bend\b/}/g;
        my %declared;
        s/^(\s*)(\w+)(\s*=\s*)/$1@{[ $declared{$2} ? '' : do { $declared{$2} = 1; 'my ' } ]}\$$2$3/gm;
        s/^(\s*)(\w+)\s*\.\s*chomp\!\s*$/$1chomp $2/gm;
        s/($Filter::Simple::placeholder)\.chomp/+Cinnamon::DSL::Capistrano->chomp\($1\)/g;
        s/\b(@{[join '|', map { quotemeta } keys %declared]})\b/\$$1/g
            if keys %declared;
        s/my \$\$/my \$/g;

        my $prev = '';
        my $line = '';
        my @value;
        for my $v (split /($Filter::Simple::placeholder)|(\x0D?\x0A)/, $_) {
            next if not defined $v or not length $v;
            if ($v =~ /^$Filter::Simple::placeholder$/) {
                $prev = $;;
                $line .= $;;
                push @value, $v;
            } elsif ($prev eq $;) {
                $prev = "$;-inner";
            } elsif ($v =~ /\x0A/) {
                if ($prev ne "\x0A" &&
                    length $prev &&
                    $prev !~ /[{,]\s*$/) {
                    if ($line =~ /^\s*(?>[\w']|$;)+\s*=>\s*(?>[\w']|$;)+\s*$/) {
                        $line = '';
                        $prev = "\x0A";
                        push @value, "," . $v;
                    } else {
                        $line = '';
                        $prev = "\x0A";
                        push @value, ";" . $v;
                    }
                } else {
                    $line = '';
                    $prev = "\x0A";
                    push @value, $v;
                }
            } else {
                $line .= $v;
                $prev = $v;
                push @value, $v;
            }
        }
        $_ = join '', @value;
    },
    string => sub {
        s/\@/\\@/g;
        s/#\{(\w+)\}/\@{[get '$1']}/g;
        s/#\{ENV\[([^\[\]]+)\]\}/\$ENV{$1}/g;
    };

my $orig_import = \&import;
*import = sub { };

sub convert {
    my (undef, @line) = @_;
    my $filter;
    local *Filter::Simple::filter_read = sub {
        if (@line) {
            $_ .= shift @line;
            return 1;
        } else {
            return 0;
        }
    };
    local *Filter::Simple::filter_add = sub {
        $filter = $_[0];
    };
    
    $orig_import->();

    local $_ = '';
    $filter->();
    return $_;
}

sub convert_and_run {
    my $self = shift;
    my $converted = $self->convert(@_);
    
    if ($ENV{CINNAMON_CAP_DEBUG}) {
        my $i = 0;
        print STDERR "Converted script:\n";
        print STDERR join "\n", map { ++$i . ' ' . $_ } split /\n/, $converted;
        print STDERR "\n";
    }

    eval qq{
        package Cinnamon::DSL::Capistrano::Filter::converted;
        use strict;
        use warnings;
        use Cinnamon::DSL::Capistrano;
        $converted;
        1;
    } or die $@;
}

1;