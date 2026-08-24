## Derived social indices: the theft counters, restraint, reciprocity lag and
## the truce rule.
##
## These are the readouts the idea asks for ("a theft counter per cog and a
## reciprocity timeline; the moment one cog starts leaving the other's coins
## alone is the beat"), defined here so a test can assert them rather than
## eyeballing a replay.

import std/json
import sim_types

proc restraintOf*(pickups, thefts: int): JsonNode =
  ## `(pickups - thefts) / pickups` in [0, 1], **null** when pickups == 0.
  if pickups <= 0:
    return newJNull()
  ## Rounded to three decimals so the replay carries no long float tails.
  let ratio = (pickups - thefts).float / pickups.float
  %(float(int(ratio * 1000.0 + 0.5)) / 1000.0)

proc beatOrNull*(beat: int): JsonNode =
  if beat <= 0: newJNull() else: %beat

proc reciprocityLag*(firstTheftBeat: array[Seats, int], slot: int): JsonNode =
  ## `firstTheftBeat[i] - firstTheftBeat[1-i]` when both are non-null, else
  ## null. Negative means seat `i` stole first; positive means it retaliated
  ## after that many beats.
  let mine = firstTheftBeat[slot]
  let theirs = firstTheftBeat[otherSlot(slot)]
  if mine <= 0 or theirs <= 0:
    return newJNull()
  %(mine - theirs)

proc truceDue*(thefts, lastTheftBeat, beat, truceBeats: int,
    pending: bool): bool =
  ## A `truce` beat is earned for a seat at the close of beat `beat` iff:
  ##  (1) it has stolen at some point,
  ##  (2) its theft counter has not increased during the last `truceBeats`
  ##      consecutive beats, and
  ##  (3) no truce has been emitted for it since its most recent theft.
  ## Every later theft re-arms it.
  thefts >= 1 and lastTheftBeat > 0 and pending and
    (beat - lastTheftBeat) >= truceBeats
