package funkin.game;

/**
 * Compiled helper for syncing note visual properties (alpha, angle) to their
 * parent strum receptors. Replaces per-frame HScript iteration, avoiding
 * interpreter overhead from Reflect calls and closure allocations.
 */
class NoteSyncHelper {
	/**
	 * Syncs alpha and optionally angle of all alive notes to their parent strum
	 * receptor. For sustain notes, alpha is multiplied by `sustainAlphaMultiplier`.
	 *
	 * @param strumLines The strum line group containing all StrumLines.
	 * @param sustainAlphaMultiplier Multiplier applied to sustain note alpha (e.g. 0.6).
	 * @param syncAngle If true, also syncs note angle to receptor angle (skipping
	 *                  notes with health == -1).
	 */
	public static function syncNotesToReceptors(strumLines:Dynamic, sustainAlphaMultiplier:Float, syncAngle:Bool):Void {
		if (strumLines == null)
			return;

		var members:Array<Dynamic> = strumLines.members;
		if (members == null)
			return;

		for (strumLine in members) {
			if (strumLine == null || !strumLine.exists || !strumLine.alive)
				continue;

			var receptors:Array<Dynamic> = strumLine.members;
			if (receptors == null)
				continue;

			var notes:NoteGroup = strumLine.notes;
			if (notes == null)
				continue;

			notes.forEachAlive(function(note:Note) {
				var receptorIndex = note.noteData % receptors.length;
				var receptor:Strum = receptors[receptorIndex];
				if (receptor == null)
					return;

				note.alpha = receptor.alpha * (note.isSustainNote ? sustainAlphaMultiplier : 1.0);

				if (syncAngle && note.health != -1)
					note.angle = receptor.angle;
			});
		}
	}
}
