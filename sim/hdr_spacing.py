import sys, os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'python'))
import numpy as np
from dvbs2_ref import *
cfo=float(sys.argv[1]) if len(sys.argv)>1 else 0
d=np.loadtxt('rx_syms.txt'); z=(d[:,0]+1j*d[:,1])*np.exp(-2j*np.pi*cfo*np.arange(len(d)))
hdr=pi2bpsk(SOF_BITS)
c=np.array([abs(np.vdot(hdr,z[k:k+26])) if k>3000 else 0 for k in range(len(z)-26)])
pk=[k for k in range(1,len(c)-1) if c[k]>0.6*c.max() and c[k]>=c[k-1] and c[k]>=c[k+1]]
print(pk, np.diff(pk))
