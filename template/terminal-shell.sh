#!/bin/bash
# The shell of a JupyterLab terminal, when the Lab was started from an
# environment module (script.sh.erb sets it as Jupyter's terminal command).
#
# A Spack or Lmod Jupyter exports a PYTHONPATH of its own Python's packages. Lab
# and its kernels need that, but a terminal inherits it as well, and the tools an
# agent runs there (`biopb-mcp`, `biopb`) are a different Python's, which then
# imports the module's compiled packages ahead of its own and dies at import.
# So the terminal gets the job's own values back: what they were before the
# module was loaded, or unset if they were not set.
if [[ -n "${BIOPB_TERMINAL_PYTHONPATH+x}" ]]; then
  export PYTHONPATH="${BIOPB_TERMINAL_PYTHONPATH}"
else
  unset PYTHONPATH
fi
if [[ -n "${BIOPB_TERMINAL_PYTHONHOME+x}" ]]; then
  export PYTHONHOME="${BIOPB_TERMINAL_PYTHONHOME}"
else
  unset PYTHONHOME
fi
unset BIOPB_TERMINAL_PYTHONPATH BIOPB_TERMINAL_PYTHONHOME

# What Jupyter would have run itself: the user's shell, as a login shell (it adds
# -l when the server has no terminal of its own, as under a batch job).
exec "${SHELL:-/bin/sh}" -l
