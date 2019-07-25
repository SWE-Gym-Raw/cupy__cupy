import unittest

import cupy
from cupy import cuda
from cupy.testing import attr


@unittest.skipUnless(cuda.nccl_enabled, 'nccl is not installed')
class TestNCCL(unittest.TestCase):

    @attr.gpu
    def test_single_proc_ring(self):
        id = cuda.nccl.get_unique_id()
        comm = cuda.nccl.NcclCommunicator(1, id, 0)
        assert 0 == comm.rank_id()
        comm.destroy()

    @attr.gpu
    @unittest.skipUnless(cuda.nccl_enabled and
                         cuda.nccl.get_version() >= 2400, 'Using old NCCL')
    def test_abort(self):
        id = cuda.nccl.get_unique_id()
        comm = cuda.nccl.NcclCommunicator(1, id, 0)
        comm.abort()

    @attr.gpu
    @unittest.skipUnless(cuda.nccl_enabled and
                         cuda.nccl.get_version() >= 2400, 'Using old NCCL')
    def test_check_async_error(self):
        id = cuda.nccl.get_unique_id()
        comm = cuda.nccl.NcclCommunicator(1, id, 0)
        comm.check_async_error()
        comm.destroy()

    @attr.gpu
    def test_init_all(self):
        comm = cuda.nccl.NcclCommunicator.initAll(1)
        assert 0 == comm.rank_id()
        comm.destroy()

    @attr.gpu
    def test_single_proc_single_dev(self):
        comm = cuda.nccl.NcclCommunicator.initAll(1)
        comm.groupStart()
        for rank in range(1):
            comm.setCurrentComm(rank)
            sendbuf = cupy.arange(10)
            recvbuf = cupy.zeros_like(sendbuf)
            comm.allReduce(sendbuf.data.ptr, recvbuf.data.ptr, 10,
                           cuda.nccl.NCCL_INT64, cuda.nccl.NCCL_SUM,
                           cuda.Stream.null.ptr)
        comm.groupEnd()
        assert cupy.allclose(sendbuf, recvbuf)
