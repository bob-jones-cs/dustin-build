package funkin.game;

import flixel.graphics.frames.FlxFramesCollection;
import funkin.backend.utils.CoolUtil;
import funkin.options.Options;

using StringTools;

/**
 * Compiled helper for bulk note reskinning.
 *
 * Moving the per-note iteration out of HScript and into native code
 * eliminates the interpreter overhead that dominates the cost when
 * hundreds of notes must be updated in a single frame.
 */
class NoteReskinHelper {

	/**
	 * Reskins all notes in the given strumlines whose strumTime falls
	 * within [eventTime, eventEndTime).
	 *
	 * Uses binary search on the descending-sorted note array to jump
	 * directly to the relevant range, avoiding iteration over notes
	 * belonging to other events.
	 *
	 * @param strumLineMembers  Array of StrumLine objects to iterate.
	 * @param frames            FlxFramesCollection for non-pixel skins (ignored when isPixel is true).
	 * @param eventTime         Song-position of the event (ms).  Start of the time range (inclusive).
	 * @param eventEndTime      Song-position of the next event (ms).  End of the time range (exclusive).
	 *                          Pass Math.POSITIVE_INFINITY for the last event.
	 * @param isPixel           Whether the target skin uses pixel-art tile sheets.
	 * @param scale             Scale to apply (e.g. daPixelZoom or finalNotesScale).
	 * @param gapFix            Gap-fix value for the target skin (3.5 for "default", 0 otherwise).
	 * @param scrollSpeed       Current scroll speed, for sustain-length recalculation.
	 * @param defaultSkin       The stage's default note skin name (skip reskinning if skin matches).
	 * @param skin              The skin name being applied by this event.
	 * @param scrollPrefixes    Four frame-name prefixes for scroll animations, one per direction.
	 * @param holdPrefixes      Four frame-name prefixes for hold-piece animations.
	 * @param holdEndPrefixes   Four frame-name prefixes for hold-end animations.
	 * @param pixelEndsGraphic  Graphic asset for pixel sustain-end tiles (nullable).
	 * @param pixelNoteW        Tile width for pixel notes (default 17).
	 * @param pixelNoteH        Tile height for pixel notes (default 17).
	 * @param pixelEndsW        Tile width for pixel sustain-end tiles (default 7).
	 * @param pixelEndsH        Tile height for pixel sustain-end tiles (default 6).
	 */
	public static function reskinNotes(
		strumLineMembers:Dynamic,
		frames:Dynamic,
		eventTime:Float,
		eventEndTime:Float,
		isPixel:Bool,
		scale:Float,
		gapFix:Float,
		scrollSpeed:Float,
		defaultSkin:String,
		skin:String,
		scrollPrefixes:Dynamic,
		holdPrefixes:Dynamic,
		holdEndPrefixes:Dynamic,
		?pixelEndsGraphic:Dynamic,
		pixelNoteW:Int = 17,
		pixelNoteH:Int = 17,
		pixelEndsW:Int = 7,
		pixelEndsH:Int = 6
	):Void {
		// If we're changing back to the default skin, the notes in
		// this event's range were never changed away from default,
		// so there is nothing to reskin.
		if (skin == defaultSkin)
			return;

		var strumLines:Array<StrumLine> = cast strumLineMembers;

		// ── Pre-compute animation frame indices (non-pixel only) ──
		// One scan of the spritesheet replaces hundreds of per-note
		// addByPrefix calls, each of which does its own O(F) scan.
		var scrollAnims:Array<Array<Int>> = null;
		var holdAnims:Array<Array<Int>> = null;
		var holdEndAnims:Array<Array<Int>> = null;

		if (!isPixel && frames != null) {
			scrollAnims = [[], [], [], []];
			holdAnims   = [[], [], [], []];
			holdEndAnims = [[], [], [], []];

			var fc:FlxFramesCollection = cast frames;
			var allFrames = fc.frames;
			for (fi in 0...allFrames.length) {
				var fname = allFrames[fi].name;
				if (fname == null) continue;
				for (d in 0...4) {
					if (fname.startsWith(scrollPrefixes[d]))       { scrollAnims[d].push(fi);   break; }
					else if (fname.startsWith(holdPrefixes[d]))    { holdAnims[d].push(fi);     break; }
					else if (fname.startsWith(holdEndPrefixes[d])) { holdEndAnims[d].push(fi);  break; }
				}
			}
		}

		var len = 0.45 * CoolUtil.quantize(scrollSpeed, 100);
		var aa = Options.antialiasing;

		for (strumLine in strumLines) {
			if (strumLine == null) continue;

			var members = strumLine.notes.members;
			var count = members.length;

			// ── Binary search ──
			// Notes are sorted descending by strumTime.  Find the first
			// index whose strumTime < eventEndTime — that's where our
			// target range begins.
			var lo = 0;
			var hi = count;
			while (lo < hi) {
				var mid = (lo + hi) >>> 1;
				var m = members[mid];
				// If null, scan left for a valid note.
				if (m == null) {
					var j = mid - 1;
					while (j >= lo && members[j] == null) j--;
					if (j < lo) { lo = mid + 1; continue; }
					m = members[j];
					mid = j;
				}
				if (m.strumTime >= eventEndTime)
					lo = mid + 1;
				else
					hi = mid;
			}

			// Iterate from lo (first note in range) until strumTime < eventTime.
			var i = lo;
			while (i < count) {
				var note = members[i];
				i++;
				if (note == null) continue;
				if (note.strumTime < eventTime) break;
				if (note.wasGoodHit || note.tooLate) continue;
				if (note.noteTypeID != 0) continue;

				// ── Preserve current animation state ──
				var oldAnimName:String = note.animation.name;
				var oldAnimFrame:Int = 0;
				if (note.animation.curAnim != null)
					oldAnimFrame = note.animation.curAnim.curFrame;

				if (isPixel) {
					if (note.isSustainNote) {
						var endsPath:String = cast pixelEndsGraphic;
						note.loadGraphic(endsPath, true, pixelEndsW, pixelEndsH);
						note.animation.add("hold", [note.noteData]);
						note.animation.add("holdend", [4 + note.noteData]);
					} else {
						var notePath:String = cast frames;
						note.loadGraphic(notePath, true, pixelNoteW, pixelNoteH);
						note.animation.add("scroll", [4 + note.noteData]);
					}
					note.antialiasing = false;
				} else {
					note.frames = cast frames;
					var d = note.noteData % 4;
					note.animation.add("scroll",  scrollAnims[d]);
					note.animation.add("hold",    holdAnims[d]);
					note.animation.add("holdend", holdEndAnims[d]);
					note.antialiasing = aa;
				}

				note.scale.set(scale, scale);
				note.animation.play(oldAnimName, true);
				if (note.animation.curAnim != null)
					note.animation.curAnim.curFrame = oldAnimFrame;

				note.updateHitbox();
				note.gapFix = gapFix;

				if (note.nextSustain != null) {
					note.scale.y = (note.sustainLength * len) / note.frameHeight;
					note.updateHitbox();
					note.scale.y += note.gapFix / note.frameHeight;
				}
			}
		}
	}
}
