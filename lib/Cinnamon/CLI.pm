package Cinnamon::CLI;
use strict;
use warnings;

use Getopt::Long;
use Cinnamon;

sub new {
    my $class = shift;
    bless { }, $class;
}

sub cinnamon {
    my $self = shift;
    $self->{cinnamon} ||= Cinnamon->new;
}

sub run {
    my ($self, @args) = @_;

    local @ARGV = @args;
    my $p = Getopt::Long::Parser->new(
        config => ["no_ignore_case", "pass_through"],
    );
    $p->getoptions(
        "u|user=s"   => \$self->{user},
        "h|help"     => \$self->{help},
        "c|config=s" => \$self->{config},
    );
    return $self->usage if $self->{help};

    $self->{config} ||= 'config/deploy.pl';
    if (!-e $self->{config}) {
        $self->print("cannot find config file for deploy : $self->{config}\n");
        return $self->usage;
    }


    my ($role, $task) = @ARGV;
    if (not defined $role) {
        require Cinnamon::Task::Cinnamon;
        $role = '';
        $task = 'cinnamon:role:list';
    } elsif (not defined $task) {
        require Cinnamon::Task::Cinnamon;
        $task = 'cinnamon:task:list';
    }
    
    $self->cinnamon->run(
        $role, $task,
        config => $self->{config},
        user => $self->{user},
    );
}

sub usage {
    my $self = shift;
    my $msg = <<"HELP";
Usage: cinnamon [--config=<path>] [--help] <role> <task>
HELP
    $self->print($msg);
}

sub print {
    my ($self, $msg) = @_;
    print STDERR $msg;
}

1;
