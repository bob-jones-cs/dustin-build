package funkin.game;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.FlxState;
import flixel.graphics.FlxGraphic;
import flixel.graphics.frames.FlxFramesCollection;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import funkin.backend.MusicBeatState;
import funkin.backend.assets.Paths;
import funkin.backend.system.modules.FunkinCache;
import openfl.utils.Assets as OpenFlAssets;

/**
 * A loading screen state that pre-loads character spritesheets and stage
 * sprites (PNG decode + Sparrow XML parse + MultiFramesCollection build)
 * before transitioning to PlayState.
 *
 * This state spreads asset-loading work across multiple frames behind a
 * progress screen, reducing the amount of synchronous work that happens
 * during PlayState.create().
 *
 * Why Paths.getFrames() instead of FlxG.bitmap.add():
 *   bitmap.add only decodes PNGs into CPU RAM. Paths.getFrames() also
 *   performs the Sparrow XML parse + MultiFramesCollection assembly that
 *   Paths.loadFrames() does, and caches the result in Paths.tempFramesCache.
 *
 * Cache survival strategy:
 *   During a state switch, multiple mechanisms conspire to destroy our
 *   preloaded data:
 *     1. preStateSwitch → Paths clears tempFramesCache
 *     2. preStateSwitch → FunkinCache.moveToSecondLayer() moves BitmapDatas
 *        to layer 2 (pending destruction)
 *     3. mapCacheAsDestroyable → sets mustDestroy=true on ALL FlxGraphics
 *     4. clearCache → destroys all FlxGraphics with mustDestroy=true
 *     5. postStateSwitch → FunkinCache.clearSecondLayer() destroys all
 *        BitmapDatas still in layer 2
 *
 *   We use preStateCreate (fires AFTER mapCacheAsDestroyable but BEFORE
 *   PlayState.create()) to:
 *     a. Restore tempFramesCache entries
 *     b. Clear mustDestroy and set persist=true on all FlxGraphics used
 *        by our preloaded frames, so clearCache (step 4) won't destroy them
 *     c. Promote BitmapDatas from FunkinCache layer 2 back to layer 1,
 *        so clearSecondLayer (step 5) won't destroy them
 */
class SongLoadingState extends MusicBeatState {
	/** Image paths to pre-load, one per frame. Each is a full asset path. */
	var assetsToLoad:Array<String> = [];
	var currentIndex:Int = 0;
	var loadingText:FlxText;
	var songDisplayName:String = "";
	var startedLoading:Bool = false;

	/** Frames we pre-built that need to survive the state switch. */
	var preloadedFrames:Map<String, FlxFramesCollection> = new Map();

	/** GPU warm-up: after CPU loading, we render preloaded textures for a few
	    frames to force OpenGL texture upload before PlayState. */
	var warmUpPhase:Bool = false;
	var warmUpFrames:Int = 0;

	override function create() {
		MusicBeatState.skipTransIn = true;
		super.create();

		if (PlayState.SONG == null) {
			MusicBeatState.skipTransOut = true;
			FlxG.switchState(new PlayState());
			return;
		}

		var dn = PlayState.SONG.meta.displayName;
		songDisplayName = (dn != null && dn != "") ? dn : PlayState.SONG.meta.name;

		trace('[SongLoadingState] Loading song: $songDisplayName');

		// Black background
		var bg = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		add(bg);

		// Loading text (centered)
		loadingText = new FlxText(0, 0, FlxG.width, 'Loading $songDisplayName...', 32);
		loadingText.setFormat(Paths.font("vcr.ttf"), 32, FlxColor.WHITE, CENTER);
		loadingText.screenCenter();
		add(loadingText);

		collectAssets();

		trace('[SongLoadingState] Found ${assetsToLoad.length} assets to preload');
	}

	/**
	 * Scans SONG.strumLines to find all character names and the stage
	 * definition, then resolves each asset's image path from its XML.
	 * We collect the image paths (the same key that FunkinSprite.loadSprite
	 * passes to Paths.getFrames) so we can call getFrames ourselves.
	 */
	function collectAssets() {
		var addedPaths:Map<String, Bool> = new Map();

		for (strumLine in PlayState.SONG.strumLines) {
			if (strumLine == null || strumLine.characters == null)
				continue;
			for (charName in strumLine.characters) {
				if (charName != null && charName != "")
					collectCharacterAssets(charName, addedPaths);
			}
		}

		collectStageAssets(addedPaths);
	}

	/**
	 * For a given character name, reads its XML to find the sprite name,
	 * then computes the full image path that FunkinSprite.loadSprite would
	 * pass to Paths.getFrames(). We store that path so update() can call
	 * Paths.getFrames(path, assetsPath=true) one per frame.
	 */
	function collectCharacterAssets(charName:String, addedPaths:Map<String, Bool>) {
		var xmlPath = Paths.xml('characters/$charName');
		if (!OpenFlAssets.exists(xmlPath))
			return;

		try {
			var xmlText = OpenFlAssets.getText(xmlPath);
			var charXML = Xml.parse(xmlText).firstElement();
			if (charXML == null)
				return;

			var spriteName = charXML.get("sprite");
			if (spriteName == null || spriteName == "")
				spriteName = charName;

			// This is exactly what Character.buildCharacter does:
			//   loadSprite(Paths.image('characters/$sprite'))
			// And FunkinSprite.loadSprite passes that path to:
			//   Paths.getFrames(path, assetsPath=true)
			var imgPath = Paths.image('characters/$spriteName');

			if (!addedPaths.exists(imgPath)) {
				addedPaths.set(imgPath, true);
				assetsToLoad.push(imgPath);
			}
		} catch (e:Dynamic) {
			// If XML parsing fails, skip — PlayState falls back to the default
			// character anyway.
		}
	}

	/**
	 * Reads the stage XML for the current song and collects all sprite
	 * image paths so they can be preloaded, reducing the work done
	 * during Stage construction inside PlayState.create().
	 */
	function collectStageAssets(addedPaths:Map<String, Bool>) {
		if (PlayState.SONG.stage == null || PlayState.SONG.stage == "")
			return;

		var stageName = PlayState.SONG.stage;
		var xmlPath = Paths.xml('stages/$stageName');
		if (!OpenFlAssets.exists(xmlPath))
			return;

		try {
			var xmlText = OpenFlAssets.getText(xmlPath);
			var stageXML = Xml.parse(xmlText).firstElement();
			if (stageXML == null)
				return;

			var folder = stageXML.get("folder");
			if (folder == null)
				folder = "";
			if (folder.length > 0 && folder.charAt(folder.length - 1) != "/")
				folder += "/";

			for (node in stageXML.elements())
				collectSpriteFromNode(node, folder, addedPaths);
		} catch (e:Dynamic) {}
	}

	/**
	 * Recursively checks an XML node and its children for sprite elements,
	 * adding their image paths to assetsToLoad.
	 */
	function collectSpriteFromNode(node:Xml, folder:String, addedPaths:Map<String, Bool>) {
		var name = node.nodeName;
		if (name == "sprite" || name == "spr" || name == "sparrow") {
			var spriteAttr = node.get("sprite");
			if (spriteAttr == null || spriteAttr == "")
				spriteAttr = node.get("name");
			if (spriteAttr != null && spriteAttr != "") {
				var imgPath = Paths.image('$folder$spriteAttr', null, true);
				if (imgPath != null && !addedPaths.exists(imgPath)) {
					addedPaths.set(imgPath, true);
					assetsToLoad.push(imgPath);
				}
			}
		}

		for (child in node.elements())
			collectSpriteFromNode(child, folder, addedPaths);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		// GPU warm-up phase: wait for textures to be uploaded by the renderer
		if (warmUpPhase) {
			warmUpFrames++;
			if (warmUpFrames >= 3) {
				trace('[SongLoadingState] GPU warm-up complete, switching to PlayState');
				installCacheSurvivalHooks();
				MusicBeatState.skipTransOut = true;
				FlxG.switchState(new PlayState());
			}
			return;
		}

		if (!startedLoading) {
			// First frame: just render the loading screen so the user sees it
			// before we start blocking on PNG decodes.
			startedLoading = true;
			updateProgress();
			return;
		}

		if (currentIndex < assetsToLoad.length) {
			var path = assetsToLoad[currentIndex];
			var frames = Paths.getFrames(path, true);
			if (frames != null)
				preloadedFrames.set(path, frames);

			currentIndex++;
			updateProgress();
		} else {
			createWarmUpSprites();
			warmUpPhase = true;
			updateProgress();
		}
	}

	/**
	 * Creates tiny invisible sprites for each unique sub-sheet BitmapData
	 * and inserts them behind the black background. When flixel renders
	 * the next frame, the OpenGL renderer uploads each BitmapData as a
	 * GPU texture, avoiding lazy texture upload costs in PlayState.
	 */
	function createWarmUpSprites() {
		var seenParents = new Map<String, Bool>();
		var count = 0;
		for (key => fc in preloadedFrames) {
			if (fc == null || fc.frames == null)
				continue;
			for (f in fc.frames) {
				if (f == null || f.parent == null || f.parent.bitmap == null)
					continue;
				var pk = f.parent.key;
				if (pk == null || seenParents.exists(pk))
					continue;
				seenParents.set(pk, true);

				// loadGraphic(BitmapData) finds or creates the FlxGraphic for
				// this BitmapData. Position on-screen with non-zero alpha so
				// flixel actually issues a draw call. insert(0, ...) places it
				// behind the opaque black background so the user sees nothing.
				var spr = new FlxSprite(0, 0);
				spr.loadGraphic(f.parent.bitmap);
				spr.alpha = 0.01;
				insert(0, spr);
				count++;
			}
		}
		trace('[SongLoadingState] Created $count warm-up sprites for GPU texture upload');
	}

	/**
	 * Registers signal listeners that protect preloaded frames across the
	 * state switch to PlayState.
	 *
	 * State switch timeline:
	 *   1. preStateSwitch → Paths clears tempFramesCache,
	 *      FunkinCache.moveToSecondLayer()
	 *   2. mapCacheAsDestroyable → mustDestroy=true on all FlxGraphics
	 *   3. *** preStateCreate fires here *** ← we act here
	 *   4. PlayState.create()
	 *   5. clearCache → destroys FlxGraphics with mustDestroy
	 *   6. postStateSwitch → clearSecondLayer destroys layer 2 BitmapDatas
	 *
	 * By acting in preStateCreate (step 3), we can undo the damage from
	 * steps 1-2 before PlayState.create() runs.
	 */
	function installCacheSurvivalHooks() {
		var savedFrames = preloadedFrames;

		FlxG.signals.preStateCreate.addOnce(function(state:FlxState) {
			// --- (a) Restore tempFramesCache ---
			// Paths.init's preStateSwitch listener already cleared it.
			// Restore our entries so PlayState.create → getFrames gets hits.
			for (key => fc in savedFrames)
				Paths.tempFramesCache.set(key, fc);

			// --- (b) Protect FlxGraphics from clearCache ---
			// mapCacheAsDestroyable set mustDestroy=true on all graphics.
			// Clear it on every FlxGraphic our frames depend on so
			// clearCache's "if (mustDestroy || ...)" check is false.
			//
			// We also set persist=true as a belt-and-suspenders measure
			// (it blocks the second half of the || condition).
			//
			// For MultiFramesCollection, each FlxFrame's parent is the
			// sub-sheet FlxGraphic (set by addFrames), and the collection's
			// parent is the dummy graphic. Protect both.
			var protectedKeys = new Map<String, Bool>();

			for (key => fc in savedFrames) {
				protectGraphic(fc.parent, protectedKeys);
				for (frame in fc.frames) {
					if (frame != null)
						protectGraphic(frame.parent, protectedKeys);
				}
			}

			// --- (c) Promote BitmapDatas from FunkinCache layer 2 → 1 ---
			// FunkinCache.moveToSecondLayer() moved all BitmapDatas to
			// bitmapData2. clearSecondLayer (on postStateSwitch) will
			// destroy anything still there. Promote ours back.
			// FunkinCache.getBitmapData promotes automatically, but it
			// modifies bitmapData2 during iteration, so collect keys first.
			var cache = FunkinCache.instance;
			if (cache != null) {
				var keysToPromote:Array<String> = [];
				for (k => bmp in cache.bitmapData2) {
					if (protectedKeys.exists(k))
						keysToPromote.push(k);
				}
				for (k in keysToPromote)
					cache.getBitmapData(k);
			}
		});
	}

	/**
	 * Clears mustDestroy and sets persist on a FlxGraphic so clearCache
	 * won't destroy it. Also records the graphic's key and assetsKey so
	 * we can promote their BitmapDatas from FunkinCache layer 2.
	 */
	static function protectGraphic(graphic:FlxGraphic, protectedKeys:Map<String, Bool>) {
		if (graphic == null)
			return;

		@:privateAccess graphic.mustDestroy = false;
		graphic.persist = true;

		// Record keys for BitmapData promotion
		if (graphic.key != null)
			protectedKeys.set(graphic.key, true);
		if (graphic.assetsKey != null)
			protectedKeys.set(graphic.assetsKey, true);
	}

	function updateProgress() {
		if (loadingText == null)
			return;
		var total = assetsToLoad.length;
		if (total == 0) {
			loadingText.text = 'Loading $songDisplayName...';
		} else {
			var pct = Math.floor((currentIndex / total) * 100);
			loadingText.text = 'Loading $songDisplayName... $pct%';
		}
	}
}
