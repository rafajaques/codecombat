ThangType = require 'models/ThangType'
SpriteParser = require 'lib/sprites/SpriteParser'
SpriteBuilder = require 'lib/sprites/SpriteBuilder'
Lank = require 'lib/surface/Lank'
LayerAdapter = require 'lib/surface/LayerAdapter'
Camera = require 'lib/surface/Camera'
DocumentFiles = require 'collections/DocumentFiles'

RootView = require 'views/kinds/RootView'
ThangComponentsEditView = require 'views/editor/component/ThangComponentsEditView'
ThangTypeVersionsModal = require './ThangTypeVersionsModal'
ThangTypeColorsTabView = require './ThangTypeColorsTabView'
PatchesView = require 'views/editor/PatchesView'
ForkModal = require 'views/editor/ForkModal'
SaveVersionModal = require 'views/modal/SaveVersionModal'
template = require 'templates/editor/thang/thang-type-edit-view'
storage = require 'lib/storage'

CENTER = {x: 200, y: 300}

module.exports = class ThangTypeEditView extends RootView
  id: 'thang-type-edit-view'
  className: 'editor'
  template: template
  resolution: 4
  scale: 3
  mockThang:
    health: 10.0
    maxHealth: 10.0
    hudProperties: ['health']
    acts: true

  events:
    'click #clear-button': 'clearRawData'
    'click #upload-button': -> @$el.find('input#real-upload-button').click()
    'change #real-upload-button': 'animationFileChosen'
    'change #animations-select': 'showAnimation'
    'click #marker-button': 'toggleDots'
    'click #stop-button': 'stopAnimation'
    'click #play-button': 'playAnimation'
    'click #history-button': 'showVersionHistory'
    'click #fork-start-button': 'startForking'
    'click #save-button': 'openSaveModal'
    'click #patches-tab': -> @patchesView.load()
    'click .play-with-level-button': 'onPlayLevel'
    'click .play-with-level-parent': 'onPlayLevelSelect'
    'keyup .play-with-level-input': 'onPlayLevelKeyUp'

  subscriptions:
    'editor:thang-type-color-groups-changed': 'onColorGroupsChanged'
    'editor:save-new-version': 'saveNewThangType'

  # init / render

  constructor: (options, @thangTypeID) ->
    super options
    @mockThang = $.extend(true, {}, @mockThang)
    @thangType = new ThangType(_id: @thangTypeID)
    @thangType = @supermodel.loadModel(@thangType, 'thang').model
    @thangType.saveBackups = true
    @listenToOnce @thangType, 'sync', ->
      @files = @supermodel.loadCollection(new DocumentFiles(@thangType), 'files').model
      @updateFileSize()
#    @refreshAnimation = _.debounce @refreshAnimation, 500

  showLoading: ($el) ->
    $el ?= @$el.find('.outer-content')
    super($el)

  getRenderData: (context={}) ->
    context = super(context)
    context.thangType = @thangType
    context.animations = @getAnimationNames()
    context.authorized = not me.get('anonymous')
    context.recentlyPlayedLevels = storage.load('recently-played-levels') ? ['items']
    context.fileSizeString = @fileSizeString
    context

  getAnimationNames: -> _.keys(@thangType.get('actions') or {})
  
  afterRender: ->
    super()
    return unless @supermodel.finished()
    @initStage()
    @buildTreema()
    @initSliders()
    @initComponents()
    @insertSubView(new ThangTypeColorsTabView(@thangType))
    @patchesView = @insertSubView(new PatchesView(@thangType), @$el.find('.patches-view'))
    @showReadOnly() if me.get('anonymous')
    @updatePortrait()

  initComponents: =>
    options =
      components: @thangType.get('components') ? []
      supermodel: @supermodel

    @thangComponentEditView = new ThangComponentsEditView options
    @listenTo @thangComponentEditView, 'components-changed', @onComponentsChanged
    @insertSubView @thangComponentEditView

  onComponentsChanged: (components) =>
    @thangType.set 'components', components

  onColorGroupsChanged: (e) ->
    @temporarilyIgnoringChanges = true
    @treema.set 'colorGroups', e.colorGroups
    @temporarilyIgnoringChanges = false

  makeDot: (color) ->
    circle = new createjs.Shape()
    circle.graphics.beginFill(color).beginStroke('black').drawCircle(0, 0, 5)
    circle.scaleY = 0.2
    circle.scaleX = 0.5
    circle

  initStage: ->
    canvas = @$el.find('#canvas')
    @stage = new createjs.Stage(canvas[0])
    @layerAdapter = new LayerAdapter({name:'Default', webGL: true})
    @topLayer = new createjs.Container()
    
    @layerAdapter.container.x = @topLayer.x = CENTER.x
    @layerAdapter.container.y = @topLayer.y = CENTER.y
    @stage.addChild(@layerAdapter.container, @topLayer)
    @listenTo @layerAdapter, 'new-spritesheet', @onNewSpriteSheet
    @camera?.destroy()
    @camera = new Camera canvas

    @torsoDot = @makeDot('blue')
    @mouthDot = @makeDot('yellow')
    @aboveHeadDot = @makeDot('green')
    @groundDot = @makeDot('red')
    @topLayer.addChild(@groundDot, @torsoDot, @mouthDot, @aboveHeadDot)
    @updateGrid()
    _.defer @refreshAnimation
    @toggleDots(false)
    
    createjs.Ticker.setFPS(30)
    createjs.Ticker.addEventListener('tick', @stage)

  toggleDots: (newShowDots) ->
    @showDots = if typeof(newShowDots) is 'boolean' then newShowDots else not @showDots
    @updateDots()

  updateDots: ->
    @topLayer.removeChild(@torsoDot, @mouthDot, @aboveHeadDot, @groundDot)
    return unless @currentLank
    return unless @showDots
    torso = @currentLank.getOffset 'torso'
    mouth = @currentLank.getOffset 'mouth'
    aboveHead = @currentLank.getOffset 'aboveHead'
    @torsoDot.x = torso.x
    @torsoDot.y = torso.y
    @mouthDot.x = mouth.x
    @mouthDot.y = mouth.y
    @aboveHeadDot.x = aboveHead.x
    @aboveHeadDot.y = aboveHead.y
    @topLayer.addChild(@groundDot, @torsoDot, @mouthDot, @aboveHeadDot)

  stopAnimation: ->
    @currentLank?.queueAction('idle')

  playAnimation: ->
    @currentLank?.queueAction(@$el.find('#animations-select').val())

  updateGrid: ->
    grid = new createjs.Container()
    line = new createjs.Shape()
    width = 1000
    line.graphics.beginFill('#666666').drawRect(-width/2, -0.5, width, 0.5)

    line.x = CENTER.x
    line.y = CENTER.y
    y = line.y
    step = 10 * @scale
    y -= step while y > 0
    while y < 500
      y += step
      newLine = line.clone()
      newLine.y = y
      grid.addChild(newLine)

    x = line.x
    x -= step while x > 0
    while x < 400
      x += step
      newLine = line.clone()
      newLine.x = x
      newLine.rotation = 90
      grid.addChild(newLine)

    @stage.removeChild(@grid) if @grid
    @stage.addChildAt(grid, 0)
    @grid = grid

  updateSelectBox: ->
    names = @getAnimationNames()
    select = @$el.find('#animations-select')
    return if select.find('option').length is names.length
    select.empty()
    select.append($('<option></option>').text(name)) for name in names

  # upload

  animationFileChosen: (e) ->
    @file = e.target.files[0]
    return unless @file
    return unless _.string.endsWith @file.type, 'javascript'
#    @$el.find('#upload-button').prop('disabled', true)
    @reader = new FileReader()
    @reader.onload = @onFileLoad
    @reader.readAsText(@file)

  onFileLoad: (e) =>
    result = @reader.result
    parser = new SpriteParser(@thangType)
    parser.parse(result)
    @treema.set('raw', @thangType.get('raw'))
    @updateSelectBox()
    @refreshAnimation()
    @updateFileSize()

  updateFileSize: ->
    file = JSON.stringify(@thangType.attributes)
    compressed = LZString.compress(file)
    size = (file.length / 1024).toFixed(1) + "KB"
    compressedSize = (compressed.length / 1024).toFixed(1) + "KB"
    gzipCompressedSize = compressedSize * 1.65  # just based on comparing ogre barracks
    @fileSizeString = "Size: #{size} (~#{compressedSize} gzipped)"
    @$el.find('#thang-type-file-size').text @fileSizeString

  # animation select

  refreshAnimation: =>
    @thangType.buildActions()
    return @showRasterImage() if @thangType.get('raster')
    options = @getLankOptions()
    console.log 'refresh animation....'
    @showAnimation()
    @updatePortrait()

  showRasterImage: ->
    lank = new Lank(@thangType, @getLankOptions())
    @showLank(lank)
    @updateScale()
    
  onNewSpriteSheet: ->
    $('#spritesheets').empty()
    for image in @layerAdapter.spriteSheet._images
      $('#spritesheets').append(image)
    @layerAdapter.container.x = CENTER.x
    @layerAdapter.container.y = CENTER.y
    @updateScale()

  showAnimation: (animationName) ->
    animationName = @$el.find('#animations-select').val() unless _.isString animationName
    return unless animationName
    @mockThang.action = animationName
    @showAction(animationName)
    @updateRotation()
    @updateScale() # must happen after update rotation, because updateRotation calls the sprite update() method.
    
  showMovieClip: (animationName) ->
    vectorParser = new SpriteBuilder(@thangType)
    movieClip = vectorParser.buildMovieClip(animationName)
    return unless movieClip
    reg = @thangType.get('positions')?.registration
    if reg
      movieClip.regX = -reg.x
      movieClip.regY = -reg.y
    scale = @thangType.get('scale')
    if scale
      movieClip.scaleX = movieClip.scaleY = scale
    @showSprite(movieClip)

  getLankOptions: -> {resolutionFactor: @resolution, thang: @mockThang}

  showAction: (actionName) ->
    options = @getLankOptions()
    lank = new Lank(@thangType, options)
    @showLank(lank)
    lank.queueAction(actionName)

  updatePortrait: ->
    options = @getLankOptions()
    portrait = @thangType.getPortraitImage(options)
    return unless portrait
    portrait?.attr('id', 'portrait').addClass('img-thumbnail')
    portrait.addClass 'img-thumbnail'
    $('#portrait').replaceWith(portrait)
    
  showLank: (lank) ->
    @clearDisplayObject()
    @clearLank()
    @layerAdapter.resetSpriteSheet()
    @layerAdapter.addLank(lank)
    @currentLank = lank

  showSprite: (sprite) ->
    @clearDisplayObject()
    @clearLank()
    @topLayer.addChild(sprite)
    @currentObject = sprite
    @updateDots()

  clearDisplayObject: ->
    @topLayer.removeChild(@currentObject) if @currentObject?
    
  clearLank: ->
    @layerAdapter.removeLank(@currentLank) if @currentLank
    @currentLank?.destroy()

  # sliders

  initSliders: ->
    @rotationSlider = @initSlider $('#rotation-slider', @$el), 50, @updateRotation
    @scaleSlider = @initSlider $('#scale-slider', @$el), 29, @updateScale
    @resolutionSlider = @initSlider $('#resolution-slider', @$el), 39, @updateResolution
    @healthSlider = @initSlider $('#health-slider', @$el), 100, @updateHealth

  updateRotation: =>
    value = parseInt(180 * (@rotationSlider.slider('value') - 50) / 50)
    @$el.find('.rotation-label').text " #{value}° "
    if @currentLank
      @currentLank.rotation = value
      @currentLank.update(true)

  updateScale: =>
    scaleValue = (@scaleSlider.slider('value') + 1) / 10
    @layerAdapter.container.scaleX = @layerAdapter.container.scaleY = @topLayer.scaleX = @topLayer.scaleY = scaleValue
    fixed = scaleValue.toFixed(1)
    @scale = scaleValue
    @$el.find('.scale-label').text " #{fixed}x "
    @updateGrid()

  updateResolution: =>
    value = (@resolutionSlider.slider('value') + 1) / 10
    fixed = value.toFixed(1)
    @$el.find('.resolution-label').text " #{fixed}x "
    @resolution = value
    @refreshAnimation()

  updateHealth: =>
    value = parseInt((@healthSlider.slider('value')) / 10)
    @$el.find('.health-label').text " #{value}hp "
    @mockThang.health = value
    @currentLank?.update()

  # save

  saveNewThangType: (e) ->
    newThangType = if e.major then @thangType.cloneNewMajorVersion() else @thangType.cloneNewMinorVersion()
    newThangType.set('commitMessage', e.commitMessage)

    res = newThangType.save()
    return unless res
    modal = $('#save-version-modal')
    @enableModalInProgress(modal)

    res.error =>
      @disableModalInProgress(modal)

    res.success =>
      url = "/editor/thang/#{newThangType.get('slug') or newThangType.id}"
      portraitSource = null
      if @thangType.get('raster')
        image = @currentLank.sprite.image
        portraitSource = imageToPortrait image
        # bit of a hacky way to get that portrait
      success = =>
        @thangType.clearBackup()
        document.location.href = url
      newThangType.uploadGenericPortrait success, portraitSource

  clearRawData: ->
    @thangType.resetRawData()
    @thangType.set 'actions', undefined
    @clearDisplayObject()
    @treema.set('/', @getThangData())

  getThangData: ->
    data = $.extend(true, {}, @thangType.attributes)
    data = _.pick data, (value, key) => not (key in ['components'])

  buildTreema: ->
    data = @getThangData()
    schema = _.cloneDeep ThangType.schema
    schema.properties = _.pick schema.properties, (value, key) => not (key in ['components'])
    options =
      data: data
      schema: schema
      files: @files
      filePath: "db/thang.type/#{@thangType.get('original')}"
      readOnly: me.get('anonymous')
      callbacks:
        change: @pushChangesToPreview
        select: @onSelectNode
    el = @$el.find('#thang-type-treema')
    @treema = @$el.find('#thang-type-treema').treema(options)
    @treema.build()
    @lastKind = data.kind

  pushChangesToPreview: =>
    return if @temporarilyIgnoringChanges
    # TODO: This doesn't delete old Treema keys you deleted
    for key, value of @treema.data
      @thangType.set(key, value)
    @updateSelectBox()
    @refreshAnimation()
    @updateDots()
    @updatePortrait()
    if (kind = @treema.data.kind) isnt @lastKind
      @lastKind = kind
      Backbone.Mediator.publish 'editor:thang-type-kind-changed', kind: kind
      if kind in ['Doodad', 'Floor', 'Wall'] and not @treema.data.terrains
        @treema.set '/terrains', ['Grass', 'Dungeon', 'Indoor']  # So editors know to set them.

  onSelectNode: (e, selected) =>
    selected = selected[0]
    @topLayer.removeChild(@boundsBox) if @boundsBox
    return @stopShowingSelectedNode() if not selected
    path = selected.getPath()
    parts = path.split('/')
    return @stopShowingSelectedNode() unless parts.length >= 4 and path.startsWith '/raw/'
    key = parts[3]
    type = parts[2]
    vectorParser = new SpriteBuilder(@thangType)
    obj = vectorParser.buildMovieClip(key) if type is 'animations'
    obj = vectorParser.buildContainerFromStore(key) if type is 'containers'
    obj = vectorParser.buildShapeFromStore(key) if type is 'shapes'
    
    bounds = obj?.bounds or obj?.nominalBounds
    if bounds
      @boundsBox = new createjs.Shape()
      @boundsBox.graphics.beginFill('#aaaaaa').beginStroke('black').drawRect(bounds.x, bounds.y, bounds.width, bounds.height)
      @topLayer.addChild(@boundsBox)
      obj.regX = @boundsBox.regX = bounds.x + bounds.width / 2
      obj.regY = @boundsBox.regY = bounds.y + bounds.height / 2
    
    @showSprite(obj) if obj
    @showingSelectedNode = true
    @currentLank?.destroy()
    @currentLank = null
    @updateScale()
    @grid.alpha = 0.0

  stopShowingSelectedNode: ->
    return unless @showingSelectedNode
    @grid.alpha = 1.0
    @showAnimation()
    @showingSelectedNode = false

  showVersionHistory: (e) ->
    @openModalView new ThangTypeVersionsModal thangType: @thangType, @thangTypeID

  openSaveModal: ->
    @openModalView new SaveVersionModal model: @thangType

  startForking: (e) ->
    @openModalView new ForkModal model: @thangType, editorPath: 'thang'

  onPlayLevelSelect: (e) ->
    if @childWindow and not @childWindow.closed
      # We already have a child window open, so we don't need to ask for a level; we'll use its existing level.
      e.stopImmediatePropagation()
      @onPlayLevel e
    _.defer -> $('.play-with-level-input').focus()

  onPlayLevelKeyUp: (e) ->
    return unless e.keyCode is 13  # return
    input = @$el.find('.play-with-level-input')
    input.parents('.dropdown').find('.play-with-level-parent').dropdown('toggle')
    level = _.string.slugify input.val()
    return unless level
    @onPlayLevel null, level
    recentlyPlayedLevels = storage.load('recently-played-levels') ? []
    recentlyPlayedLevels.push level
    storage.save 'recently-played-levels', recentlyPlayedLevels

  onPlayLevel: (e, level=null) ->
    level ?= $(e.target).data('level')
    level = _.string.slugify level
    if @childWindow and not @childWindow.closed
      # Reset the LevelView's world, but leave the rest of the state alone
      @childWindow.Backbone.Mediator.publish 'level:reload-thang-type', thangType: @thangType
    else
      # Create a new Window with a blank LevelView
      scratchLevelID = level + '?dev=true'
      if me.get('name') is 'Nick'
        @childWindow = window.open("/play/level/#{scratchLevelID}", 'child_window', 'width=2560,height=1080,left=0,top=-1600,location=1,menubar=1,scrollbars=1,status=0,titlebar=1,toolbar=1', true)
      else
        @childWindow = window.open("/play/level/#{scratchLevelID}", 'child_window', 'width=1024,height=560,left=10,top=10,location=0,menubar=0,scrollbars=0,status=0,titlebar=0,toolbar=0', true)
    @childWindow.focus()

  destroy: ->
    @camera?.destroy()
    super()

imageToPortrait = (img) ->
  canvas = document.createElement('canvas')
  canvas.width = 100
  canvas.height = 100
  ctx = canvas.getContext('2d')
  scaleX = 100 / img.width
  scaleY = 100 / img.height
  ctx.scale scaleX, scaleY
  ctx.drawImage img, 0, 0
  canvas.toDataURL('image/png')
