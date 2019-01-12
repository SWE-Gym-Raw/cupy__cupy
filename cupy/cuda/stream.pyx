from cupy.cuda import runtime
import threading
import weakref


cdef object _thread_local = threading.local()


cdef class _StreamThreadLocal(object):
    cdef void* current_stream
    cdef object current_stream_ref
    cdef list prev_stream_ref_stack

    @staticmethod
    cdef _StreamThreadLocal get():
        tls = getattr(_thread_local, 'tls', None)
        if tls is None:
            c_tls = _StreamThreadLocal()
            _thread_local.tls = c_tls
            return c_tls
        return <_StreamThreadLocal>tls

    cdef set_current_stream(self, stream):
        cdef void* stream_ptr
        if stream is None:
            stream = Stream.null
            stream_ptr = <void*>0
        else:
            stream_ptr = <void*><size_t>stream.ptr

        self.current_stream = stream_ptr
        self.current_stream_ref = weakref.ref(stream)

    cdef get_current_stream(self):
        if self.current_stream_ref is None:
            self.current_stream_ref = weakref.ref(Stream.null)
        return self.current_stream_ref()

    cdef void* get_current_stream_ptr(self):
        # Returns nullptr if not set, which is equivalent to the default
        # stream.
        return self.current_stream


cdef size_t get_current_stream_ptr():
    """C API to get current CUDA stream pointer.

    Returns:
        size_t: The current CUDA stream pointer.
    """
    tls = _StreamThreadLocal.get()
    return <size_t>tls.get_current_stream_ptr()


cpdef get_current_stream():
    """Gets current CUDA stream.

    Returns:
        cupy.cuda.Stream: The current CUDA stream.
    """
    tls = _StreamThreadLocal.get()
    return tls.get_current_stream()


class Event(object):

    """CUDA event, a synchronization point of CUDA streams.

    This class handles the CUDA event handle in RAII way, i.e., when an Event
    instance is destroyed by the GC, its handle is also destroyed.

    Args:
        block (bool): If ``True``, the event blocks on the
            :meth:`~cupy.cuda.Event.synchronize` method.
        disable_timing (bool): If ``True``, the event does not prepare the
            timing data.
        interprocess (bool): If ``True``, the event can be passed to other
            processes.

    Attributes:
        ~Event.ptr (size_t): Raw stream handle. It can be passed to
            the CUDA Runtime API via ctypes.

    """

    def __init__(self, block=False, disable_timing=False, interprocess=False):
        self.ptr = 0

        if interprocess and not disable_timing:
            raise ValueError('Timing must be disabled for interprocess events')
        flag = ((block and runtime.eventBlockingSync) |
                (disable_timing and runtime.eventDisableTiming) |
                (interprocess and runtime.eventInterprocess))
        self.ptr = runtime.eventCreateWithFlags(flag)

    def __del__(self):
        if self.ptr:
            runtime.eventDestroy(self.ptr)

    @property
    def done(self):
        """True if the event is done."""
        return runtime.eventQuery(self.ptr) == 0  # cudaSuccess

    def record(self, stream=None):
        """Records the event to a stream.

        Args:
            stream (cupy.cuda.Stream): CUDA stream to record event. The null
                stream is used by default.

        .. seealso:: :meth:`cupy.cuda.Stream.record`

        """
        if stream is None:
            stream_ptr = get_current_stream_ptr()
        else:
            stream_ptr = stream.ptr
        runtime.eventRecord(self.ptr, stream_ptr)

    def synchronize(self):
        """Synchronizes all device work to the event.

        If the event is created as a blocking event, it also blocks the CPU
        thread until the event is done.

        """
        runtime.eventSynchronize(self.ptr)


def get_elapsed_time(start_event, end_event):
    """Gets the elapsed time between two events.

    Args:
        start_event (Event): Earlier event.
        end_event (Event): Later event.

    Returns:
        float: Elapsed time in milliseconds.

    """
    return runtime.eventElapsedTime(start_event.ptr, end_event.ptr)


class Stream(object):

    """CUDA stream.

    This class handles the CUDA stream handle in RAII way, i.e., when an Stream
    instance is destroyed by the GC, its handle is also destroyed.

    Args:
        null (bool): If ``True``, the stream is a null stream (i.e. the default
            stream that synchronizes with all streams). Otherwise, a plain new
            stream is created. Note that you can also use ``Stream.null``
            singleton object instead of creating new null stream object.
        non_blocking (bool): If ``True``, the stream does not synchronize with
            the NULL stream.

    Attributes:
        ~Stream.ptr (size_t): Raw stream handle. It can be passed to
            the CUDA Runtime API via ctypes.

    """

    null = None

    def __init__(self, null=False, non_blocking=False):
        if null:
            self.ptr = 0
        elif non_blocking:
            self.ptr = runtime.streamCreateWithFlags(runtime.streamNonBlocking)
        else:
            self.ptr = runtime.streamCreate()

    def __del__(self):
        if self.ptr:
            tls = _StreamThreadLocal.get()
            current_ptr = tls.get_current_stream_ptr()
            if self.ptr == <size_t>current_ptr:
                tls.set_current_stream(self.null)
            runtime.streamDestroy(self.ptr)
        # Note that we can not release memory pool of the stream held in CPU
        # because the memory would still be used in kernels executed in GPU.

    def __eq__(self, other):
        # This operator is implemented to compare the singleton instance
        # of null stream (Stream.null) can safely be compared with null
        # stream instance created by a user.
        return self.ptr == other.ptr

    def __enter__(self):
        tls = _StreamThreadLocal.get()
        if tls.prev_stream_ref_stack is None:
            tls.prev_stream_ref_stack = []
        prev_stream_ref = weakref.ref(tls.get_current_stream())
        tls.prev_stream_ref_stack.append(prev_stream_ref)
        tls.set_current_stream(self)
        return self

    def __exit__(self, *args):
        tls = _StreamThreadLocal.get()
        prev_stream_ref = tls.prev_stream_ref_stack.pop()
        tls.set_current_stream(prev_stream_ref())
        pass

    def use(self):
        """Makes this stream current.

        If you want to switch a stream temporarily, use the *with* statement.
        """
        tls = _StreamThreadLocal.get()
        tls.set_current_stream(self)
        return self

    @property
    def done(self):
        """True if all work on this stream has been done."""
        return runtime.streamQuery(self.ptr) == 0  # cudaSuccess

    def synchronize(self):
        """Waits for the stream completing all queued work."""
        runtime.streamSynchronize(self.ptr)

    def add_callback(self, callback, arg):
        """Adds a callback that is called when all queued work is done.

        Args:
            callback (function): Callback function. It must take three
                arguments (Stream object, int error status, and user data
                object), and returns nothing.
            arg (object): Argument to the callback.

        """
        def f(stream, status, dummy):
            callback(self, status, arg)
        runtime.streamAddCallback(self.ptr, f, 0)

    def record(self, event=None):
        """Records an event on the stream.

        Args:
            event (None or cupy.cuda.Event): CUDA event. If ``None``, then a
                new plain event is created and used.

        Returns:
            cupy.cuda.Event: The recorded event.

        .. seealso:: :meth:`cupy.cuda.Event.record`

        """
        if event is None:
            event = Event()
        runtime.eventRecord(event.ptr, self.ptr)
        return event

    def wait_event(self, event):
        """Makes the stream wait for an event.

        The future work on this stream will be done after the event.

        Args:
            event (cupy.cuda.Event): CUDA event.

        """
        runtime.streamWaitEvent(self.ptr, event.ptr)


Stream.null = Stream(null=True)
