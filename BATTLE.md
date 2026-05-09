# Battle Engagement

This file defines the unit collision battle rule for the RTS prototype.

## Goal

After both players finish setup and gameplay starts, mobile units should not slide past enemy units they collide with. If opposing forces meet, they should stop, fight the local enemy, and only continue toward the enemy citadel after the immediate enemy contact is destroyed or no longer blocking them.

## Gameplay Rule

- Battle engagement only runs during the `playing` phase.
- Mobile combatants are `infantry`, `captain`, `artillery`, and `imperator`.
- A mobile unit is considered engaged when either:
  - an active enemy mobile unit is on an adjacent tile, including diagonals, or
  - the next tile the unit wants to step into is occupied by an active enemy object.
- Engaged units do not move on that simulation step.
- Engaged units continue using the normal combat system while stopped.
- When no adjacent enemy or enemy blocker remains, the unit resumes movement toward the enemy citadel.

## Combat Targeting

- Units prefer nearby enemy combatants over distant objectives once contact starts.
- Contact range includes diagonal adjacency so opposing formations can fight when their tile footprints touch.
- Structures can still be attacked by normal weapon range rules.
- Destroyed enemies are marked inactive and no longer block movement.

## Pathing Interaction

- Pathfinding still points units toward the enemy citadel approach tile.
- Engagement is evaluated immediately before a unit commits to its next movement step.
- This keeps the flow-field pathing simple while preventing units from walking around or through local enemy contact.

## Verification

- Unit tests should cover that adjacent enemies stop moving and deal damage.
- Unit tests should cover that a unit resumes moving after the adjacent enemy is destroyed.
- Native and web builds should remain consistent because the rule lives in shared runtime simulation code.
