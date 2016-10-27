package Net::Amazon::S3::Client::AsyncHandle;

use strict;
use warnings;

use Moose 0.85;
use MooseX::StrictConstructor 0.16;
use HTTP::Async;

=head1 NAME

WebService::HRXML::AsyncResponse

=head1 SYNOPSIS

  my $async = $parser->parse_resume_async(...);
  ... do something ...
  $async->poke(); #keeps the connection alive and the flowing
  ... do more ...
  $async->poke();
  ... collect ...
  my $result = $async->await();
  ... or ...
  my ($result, $id) = $async->await();
  ... do something with result ...
  my $original_document = $docs->{$id};
  print "$original_document - $result";
  ... try to wait for the next object ...
  $result = $async->await();
  .. we have no request so await returns undef ...

=head1 DESCRIPTION

This is a simple wrapper object that simplifies working with
an Async Resume parsing HTTP request. Without it L<WebService::HRXML>
would push the responsibility of validating, parsing, and dealing with
the return data from a WebService call onto the consumer of the class, you!

You really don't to deal with that right?

That said, there is no such thing as a free lunch so read below for a description of
what's going on.

=head1 SO WHAT ABOUT THIS WHOLE ASYNC THING

Async means we're relying on the OS' IO buffering and multiplexing
to Do The Right Thing(TM) to provide concurrency. This is accomplished
via L<HTTP::Async> and that class' underlying L<Net::HTTP::NB> instance.

Async/Concurrency does NOT imply that we have any sort of event loop running, threads,
forks, fibers, co-routines, or any other imaginable parallelism mechanism.
This is as dead simple as it gets from a user space point of view
(we'll let Kernel developers worry about the details).

Here's a quick picture of the difference between concurrency and parallelism:
* Unit of Work
= Blocking

  Concurrency:

  *==***==***=*

  Parallelism

  *
  ==*
  *
  *
  ==*
  *
  *
  =*

  Concurrency AND Parallelism

  *==***
  ==***=*

The total (CPU) time taken is the same. The total work done is the same. This is similar to the
concept in physics of levers reducing the effort exerted but not the work done. The nitty gritty of
the trade offs of each approach is different.

Case 1 is very friendly to your processes neighbors as everything is done in one process with one
block of memory in linear time. It's as if you bundled all your HTTP requests into one and pushed the
responsibility of figuring it all our onto the recipient. It's very simple (no forks, threads, etc).
and fantastic when you'd otherwise be blocked by some other logic (i.e. writing to files or doing a
bunch of DB inserts).

Case 2 is CPU greedy and Memory greedy relative to Case 1, but for a few HTTP requests on a lightly
loaded server, no one will care. If you're in a case where you're blocked by some other logic, its
less than awesome because you're hurrying to a red light. Compared to Case 1 this approach takes
less wall-clock time. Running too many processes could lead to inefficiencies due to all the context
switching. 100 processes on a single core for simple requests may end up being slower than more
concurrency on fewer processes; which leads us to...

Case 3 is the mixed case and is awesome when your blockers benefit from parallelism or you have a lot of
tasks you want to run. I.e. parsing 1000 resumes in one go will likely benefit from 10 forks with 100 tasks
a piece. L<HTTP::Async> has a default limiter of 20 concurrent requests at once, so if the web service has enough
capacity to keep your connections filled with data and your machine a sufficient number of cores and memory,
you could attempt use the equation: $desired_processes = $resumes / 20.

When you have lots of resumes to parse and you need them done ASAP, this should be faster than case 1 and 2.

=head1 POKING AT YOUR REQUEST(S)

The poke method is provided as a pass through to L<HTTP::Async>'s poke method. Because we're blocking the
process to perform housekeeping the poke method needs to be called periodically to perform those tasks.
You should aim to call poke or a method that calls poke (like is_complete or await) every few seconds at most to ensure
your data isn't flushed from its buffer. In my testing an HTTP 504 is the likely error when you fail to call
poke when you have otherwise good data. See the unit test at app/t-live/WebService/HRXML/parser.t for an
example of a long running call.

=head1 BATCHING REQUESTS

This class is designed to work with the capabilities of L<HTTP::Async> and it's reasonable to expect batched
APIs to be implemented using this class as a return type. The flow for those will be something like:

  my $async = $parser->some_batched_call(...);
  ... do something ...
  while (my $result = $async->await()){
    $foo->bar($result);
  }

You might be running a highly parallel task with a whole bunch of concurrent parses happening. If you have
the memory to let your backlog run you can have an event loop that works something like:

  my $async = $parser->some_batched_call(...);
  while (1){
    if ($async->is_complete()){
      while (my $result = $async->await()){
        $foo->bar($result);
      }
    } else {
      if (my $data = whatever_this_thing_does()){
        fork_and_do_thing_a();
        $async->poke();
        fork_and_do_thing_b();
        $async->poke();
        run_something_in_the_main_process();
      }
    }
  }

As mentioned above, the is_complete and await methods will perform the same duties as poke
so you do not need to call it explicitly in the first conditional body.

=head1 ATTRIBUTES

=head2 async_ua

A handle to an instance of L<HTTP::Async>

=cut

has 'client' =>
    ( is => 'ro', isa => 'Net::Amazon::S3::Client', required => 1 );

=head2 task_map

A mapping of HTTP::Async requests IDs with the resource IDs passed
in with the request data. If no resource ID is specified at request
time the dictionary will be mapped from the request ID to the request ID
for the sake of code simplicity.

=cut

has 'task_map' => (
  is        => 'ro',
  isa       => 'HashRef',
  default   => sub { return {} },
);

=head2 last_await_id

Contains the last ID returned by a call to await

=cut

has 'last_await_id' => (
  is        => 'rw',
  isa       => 'Maybe[Str]',
);

=head1 METHODS

=head2 poke

Useful when you plan on collecting your result with await
seconds after starting your request.

Calls the UA's poke method so it can perform house keeping.

=cut

sub poke {
  my ($self) = @_;
  $self->client->async_ua->poke();
}

=head2 has_response

Returns true if a response is ready to be read by await

=cut

sub has_response {
  return !!shift->client->async_ua->to_return_count();
}

=head2 is_complete

Returns true if nothing is pending to return

=cut

sub is_complete {
  my ($self) = @_;
  return !$self->client->async_ua->total_count();
}

=head2 await

Blocks the process to wait for the UA to complete it's request
and calls the necessary L<Webservice::HRXML> methods to return
the same value as you'd expect from a synchronous call.

If no data is returned from the UA, undef is returned by this method.
No exceptions are caught by this method so guard against exceptions
in your code.

When called in list context the parser's return value and the resource ID
for the parsed document is returned. The ID is specified in the call to
WebService::HRXML. If no ID was specified, the HTTP::Async task id is
returned instead.

=cut

sub await {
  my ($self) = @_;
  if (my ($response, $async_id) = $self->client->async_ua->wait_for_next_response()){
    my $task_id = $self->task_map->{$async_id};
    $self->last_await_id($task_id);
    my $ret_val = WebService::HRXML->handle_parser_data($response);
    return wantarray ? ($ret_val, $task_id) : $ret_val;
  }

  return wantarray ? (undef, undef) : undef;
}

1;
