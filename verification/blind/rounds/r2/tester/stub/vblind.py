"""vblind: the interface every implementation in this exercise exposes.

Hand-written by the orchestrator as a neutral contract. It says WHAT goes in and comes out and in which
representation; it deliberately says nothing about what the standards require (marker values, preamble words,
data-type codes, length units, repetition periods, padding, byte order inside a word). Those come from the
corpus only.

An implementation is one Python module (file) defining every name below with these signatures. Tests load it
by path (env var VBLIND_IMPL) and call only these names.

Representations used throughout
-------------------------------
* DSD input: one `bytes` object per channel. Bits are in time order: the most significant bit of byte 0 is the
  oldest bit of that channel, then the next most significant bit, and so on; byte 1 follows byte 0 in time.
* DoP output: a list of PCM frames; frame[n][c] is the PCM sample word of channel c in frame n, as an unsigned
  integer holding the sample's raw bit pattern (two's complement samples are NOT sign-converted). The word width
  is whatever the standard prescribes.
* IEC 61937 output: a flat list of 16-bit unsigned integers (0..0xFFFF) in transmission order on a two-channel
  consumer interface (IEC 60958, as used over S/PDIF and HDMI): element 2k is the subframe-1 (channel 1) sample of
  interface frame k, element 2k+1 the subframe-2 (channel 2) sample. Each integer is the 16-bit sample value
  (its most significant bit is the sample's most significant bit). How such a list is serialized to bytes in a
  WAV/PCM buffer is not part of the interface.
* Compressed audio frames (AC-3, E-AC-3, DTS) are `bytes` in their normal stream byte order (for AC-3 / E-AC-3 the
  first two bytes are the sync word; DTS core frames are the 16-bit big-endian form beginning with the 32-bit
  sync word).
"""
from __future__ import annotations

from dataclasses import dataclass


class DoPError(ValueError):
    """Raised for input that cannot be packed, or a PCM stream that is not valid DoP."""


class BurstError(ValueError):
    """Raised for input that cannot be framed, or a word stream that cannot be parsed."""


# --------------------------------------------------------------------------------------------------- DoP

def dop_pack(dsd: list[bytes], first_marker: int = 0x05) -> list[list[int]]:
    """Pack DSD into DoP PCM frames using the method where every PCM frame carries one sample per DSD channel
    (the base method, which the standard extends to higher DSD rates by raising the PCM rate).

    dsd: one bytes object per channel (see module docstring); all channels the same length.
    first_marker: the marker value the first returned frame must carry (lets a caller continue a stream that
        ended on the other marker).
    Returns the PCM frames, frames[n][c] as described in the module docstring.
    Raises DoPError for input this method cannot represent exactly (decide from the standard what that is) and
    for a first_marker the method doesn't use.
    """
    raise NotImplementedError


def dop_unpack(frames: list[list[int]]) -> tuple[list[bytes], int]:
    """Inverse of dop_pack: returns (dsd, first_marker) such that dop_pack(dsd, first_marker) == frames.

    Raises DoPError if `frames` is not a valid DoP stream of the base method according to the standard.
    An empty list of frames is not an error only if the standard allows it; decide and document.
    """
    raise NotImplementedError


# ---------------------------------------------------------------------------------------------- IEC 61937

def ac3_burst(frame: bytes) -> list[int]:
    """One AC-3 syncframe -> one complete data burst on the consumer interface, followed by whatever fills the
    interface until the next burst would start when bursts are sent at the format's standard repetition period.
    Returns the 16-bit words (see module docstring); len() is therefore 2 x (repetition period in frames).
    Raises BurstError if the frame cannot be carried in one burst.
    """
    raise NotImplementedError


def eac3_burst(frames: list[bytes]) -> list[int]:
    """The E-AC-3 syncframes that together make up one data burst (already grouped, see eac3_group) -> one
    complete data burst on the consumer interface plus the fill up to the next burst, as ac3_burst.
    Raises BurstError if the frames cannot be carried in one burst.
    """
    raise NotImplementedError


def eac3_group(frames: list[bytes]) -> list[list[int]]:
    """Split a sequence of E-AC-3 syncframes into the groups that each go into one data burst.
    Returns lists of indices into `frames`, in order, covering every frame exactly once.
    """
    raise NotImplementedError


def dts_burst(frame: bytes) -> list[int]:
    """One DTS core frame (16-bit big-endian form) -> one complete data burst on the consumer interface plus the
    fill up to the next burst, as ac3_burst. Everything the burst needs is taken from the frame header.
    Raises BurstError if the frame cannot be carried (decide from the sources what can be).
    """
    raise NotImplementedError


@dataclass(frozen=True)
class Burst:
    offset: int                 # index (into the word list) of the burst's first preamble word
    data_type: int
    data_type_dependent: int
    error_flag: int
    bitstream_number: int
    length_code: int            # the raw value of the length word, unconverted
    payload: bytes              # exactly the payload bytes the burst carries (per the length code and its unit)


def parse_bursts(words: list[int]) -> list[Burst]:
    """Find and decode every data burst in a consumer-interface word list (module docstring), in order.
    Raises BurstError for a burst whose preamble or length is inconsistent with the stream.
    """
    raise NotImplementedError
