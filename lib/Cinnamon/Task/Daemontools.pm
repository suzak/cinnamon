package Cinnamon::Task::Daemontools;
use strict;
use warnings;
use Cinnamon::DSL;
use Cinnamon::Logger;
use Cinnamon::Task::Process;
use Exporter::Lite;

our @EXPORT = qw(define_daemontools_tasks);

sub get_svstat ($) {
    my $service = shift;
    my ($status) = sudo 'svstat', $service;

    # /service/hoge: down 1 seconds, normally up
    # /service/hoge: up (pid 1486) 0 seconds
    # /service/hoge: up (pid 11859) 6001 seconds, want down

    if ($status =~ /.+: (up) \(pid ([0-9]+)\) ([0-9]+) seconds(?:, (want (?:down|up)))?/) {
        return {status => $1, pid => $2, seconds => $3, additional => $4};
    } elsif ($status =~ /.+: (down) ([0-9]+) seconds/) {
        return {status => $1, seconds => $2};
    } else {
        return {status => 'unknown'};
    }
}

sub define_daemontools_tasks ($;%) {
    my ($name, %args) = @_;
    my $task_ns = $args{namespace} || $name;

    my $onnotice = $args{onnotice} || sub { };

    return (
        start => sub {
            my ($host, @args) = @_;
            my $user = get 'daemontools_user';
            remote {
                my $dir = get 'daemontools_service_dir';
                my $service = get 'get_daemontools_service_name';
                sudo 'svc -u ' . $dir . '/' . $service->($name);
                $onnotice->('svc -u');

                my $status1 = get_svstat $dir . '/' . $service->($name);
                my $stable;
                my $i = 0;
                {
                    sleep 1;
                    my $status2 = get_svstat $dir . '/' . $service->($name);
                    if ($status2->{status} eq 'up' and
                        $status1->{status} eq 'up' and
                        $status1->{pid} == $status2->{pid}) {
                        $stable = 1;
                        last;
                    }

                    last if $i++ > 5;
                    sudo 'svc -u ' . $dir . '/' . $service->($name);
                    $onnotice->("svc -u ($i)");
                    $status1 = $status2;
                    redo;
                }
                die "svc -u likely failed\n"
                    unless $status1->{status} eq 'up' and $stable;
            } $host, user => $user;
        },
        stop => sub {
            my ($host, @args) = @_;
            my $user = get 'daemontools_user';
            remote {
                my $dir = get 'daemontools_service_dir';
                my $service = get 'get_daemontools_service_name';
                sudo 'svc', '-d', $dir . '/' . $service->($name);
                $onnotice->('svc -d');

                my $timeout = 20;
                my $i = 0;
                my $mode;
                {
                    my $status = get_svstat $dir . '/' . $service->($name);
                    last if $status->{status} eq 'down';
                    if ($i > 2 and
                        (not $status->{additional} or
                         $status->{additional} ne 'want down')) {
                        $mode = $i > 5 ? $i > 8 ? 'k' : 't' : 'd';
                    } elsif ($i > 7) {
                        $mode = 'k';
                    }
                    if ($mode) {
                        if ($mode eq 'd') {
                            sudo 'svc', '-d', $dir . '/' . $service->($name);
                            $onnotice->("svc -d ($i)");
                        } elsif ($mode eq 't') {
                            kill_process_descendant 15, $status->{pid};
                            $onnotice->("SIGTERM ($i)");
                        } elsif ($mode eq 'k') {
                            kill_process_descendant 9, $status->{pid};
                            $onnotice->("SIGKILL ($i)");
                        }
                    }
                    if ($i < $timeout) {
                        sleep 1;
                        $i++;
                        redo;
                    } else {
                        die "svc -d failed\n";
                    }
                }
            } $host, user => $user;
        },
        restart => sub {
            my ($host, @args) = @_;
            my $user = get 'daemontools_user';
            remote {
                my $dir = get 'daemontools_service_dir';
                my $service = get 'get_daemontools_service_name';
                my $service_dir = $dir . '/' . $service->($name);

                my $status0 = get_svstat $service_dir;
                if ($status0->{status} eq 'down' or
                    $status0->{status} eq 'unknown') {
                    call "$task_ns:start", $host, @args;
                } else {
                    $status0->{pid} ||= 0;

                    sudo 'svc', '-t', $service_dir;
                    $onnotice->('svc -t');

                    my $restarted;
                    my $stable;
                    my $i = 0;
                    my $status1;
                    {
                        $status1 = get_svstat $service_dir;
                        if ($status1->{status} eq 'up' and
                            $status1->{pid} != $status0->{pid}) {
                            $restarted = 1;
                        }
                        sleep 1;
                    }
                    {
                        my $status2 = get_svstat $service_dir;
                        if ($status2->{status} eq 'up' and
                            $status2->{pid} != $status0->{pid}) {
                            $restarted = 1;
                        }
                        if ($restarted and
                            $status1->{pid} == $status2->{pid}) {
                            $stable = 1;
                            last;
                        }
                        $status1 = $status2;
                        $i++;
                        if ($status2->{status} eq 'up' and
                            $status0->{pid} == $status2->{pid}) {
                            if ($i > 8) {
                                kill_process_descendant 9, $status2->{pid};
                                $onnotice->("SIGKILL ($i)");
                            } elsif ($i > 5) {
                                kill_process_descendant 15, $status2->{pid};
                                $onnotice->("SIGTERM ($i)");
                            } elsif ($i > 2) {
                                sudo 'svc', '-t', $service_dir;
                                $onnotice->("svc -t ($i)");
                            }
                            last if $i > 20;
                        } else {
                            last if $i > 10;
                        }
                        sleep 1;
                        redo;
                    }

                    die "svc -t failed\n" unless $restarted and $stable;
                }
            } $host, user => $user;
        },
        status => sub {
            my ($host, @args) = @_;
            my $user = get 'daemontools_user';
            remote {
                my $dir = get 'daemontools_service_dir';
                my $service = get 'get_daemontools_service_name';
                sudo 'svstat ' . $dir . '/' . $service->($name);
            } $host, user => $user;
        },
        process => {
            list => sub {
                my ($host, @args) = @_;
                my $user = get 'daemontools_user';
                remote {
                    my $dir = get 'daemontools_service_dir';
                    my $service = get 'get_daemontools_service_name';
                    my $status = get_svstat $dir . '/' . $service->($name);
                    if ($status->{status} eq 'up') {
                        my $processes = ps;
                        my $get_tree; $get_tree = sub {
                            my ($pid, $indent) = @_;
                            my $result = '';
                            my $this = $processes->{$pid};
                            if ($this) {
                                $result .= $indent . "$pid $this->{command}\n";
                            }
                            for (keys %$processes) {
                                next unless $processes->{$_}->{ppid} == $pid;
                                $result .= $get_tree->($_, $indent . '  ');
                            }
                            return $result;
                        };
                        my $parent = $processes->{$processes->{$status->{pid}}->{ppid}};
                        log info => "$parent->{pid} $parent->{command}\n" . $get_tree->($status->{pid}, '  ');
                    }
                } $host, user => $user;
            },
        },
        log => {
            restart => sub {
                my ($host, @args) = @_;
                my $user = get 'daemontools_user';
                remote {
                    my $dir = get 'daemontools_service_dir';
                    my $service = get 'get_daemontools_service_name';
                    sudo 'svc -t ' . $dir . '/' . $service->($name) . '/log';
                } $host, user => $user;
            },
            start => sub {
                my ($host, @args) = @_;
                remote {
                    my $dir = get 'daemontools_service_dir';
                    my $service = get 'get_daemontools_service_name';
                    sudo 'svc -u ' . $dir . '/' . $service->($name) . '/log';
                } $host;
            },
            stop => sub {
                my ($host, @args) = @_;
                remote {
                    my $dir = get 'daemontools_service_dir';
                    my $service = get 'get_daemontools_service_name';
                    sudo 'svc -d ' . $dir . '/' . $service->($name) . '/log';
                } $host;
            },
            status => sub {
                my ($host, @args) = @_;
                my $user = get 'daemontools_user';
                remote {
                    my $dir = get 'daemontools_service_dir';
                    my $service = get 'get_daemontools_service_name';
                    sudo 'svstat ' . $dir . '/' . $service->($name) . '/log';
                } $host, user => $user;
            },
            tail => sub {
                my ($host, @args) = @_;
                my $user = get 'daemontools_user';
                remote {
                    my $file_name = get 'get_daemontools_log_file_name';
                    run_stream "tail --follow=name " . $file_name->($name);
                } $host, user => $user;
            },
        },
        uninstall => sub {
            my ($host, @args) = @_;
            my $user = (get 'daemontools_uninstall_user') || get 'daemontools_user';
            remote {
                my $dir = get 'daemontools_service_dir';
                my $service = get 'get_daemontools_service_name';
                sudo 'mv ' . $dir . '/' . $service->($name) . ' ' . $dir . '/.' . $service->($name);
                sudo 'svc -dx ' . $dir . '/.' . $service->($name);
                sudo 'svc -dx ' . $dir . '/.' . $service->($name) . '/log';
                sudo 'rm ' . $dir . '/.' . $service->($name);
                $onnotice->('svc -x');
            } $host, user => $user;
        },
    );
}

task daemontools => {
    svscan => {
        start => sub {
            my ($host, @args) = @_;
            remote {
                sudo '/etc/init.d/svscan', 'start';
            } $host;
        },
    },
};

1;
