module.exports = (grunt) ->

  # Project configuration.
  grunt.initConfig
    pkg: grunt.file.readJSON 'package.json'
    uglify:
      options:
        banner: '/*! <%= pkg.name %> <%= grunt.template.today("yyyy-mm-dd") %> */\n'

      build:
        src: 'build/<%= pkg.name %>.js'
        dest: 'build/<%= pkg.name %>.min.js'

    coffeelint:
        app: ['src/*.coffee', 'test/*.coffee']
        options:
          no_trailing_whitespace:
            level: 'ignore'  # PyCharm can't just autostrip for .coffee, needed for .jade
          max_line_length:
            level: 'ignore'
          line_endings:
            value: "unix"
            level: "error"

    watch:
      files: ['src/**/*', 'test/**/*.coffee']
      tasks: ['coffeelint', 'coffee', 'browserify', 'concat', 'jasmine_node']  #, 'uglify']
      options:
        spawn: false

    #jasmine:
    #  aetherTests:
    #    src: ['build/<%= pkg.name %>.js']
    #    options:
    #      specs: ['']

    "jasmine_node":
      run:
        spec: "lib/test/"
      env:
        NODE_PATH: "lib"
      executable: './node_modules/.bin/jasmine_node'

    coffee:
      compile:
        files: [
            expand: true         # Enable dynamic expansion.
            cwd: 'src/'          # Src matches are relative to this path.
            src: ['**/*.coffee'] # Actual pattern(s) to match.
            dest: 'lib/'         # Destination path prefix.
            ext: '.js'           # Dest filepaths will have this extension.
          ,
            expand: true         # Enable dynamic expansion.
            cwd: 'test/'         # Src matches are relative to this path.
            src: ['**/*.coffee'] # Actual pattern(s) to match.
            dest: 'lib/test/'    # Destination path prefix.
            ext: '.js'           # Dest filepaths will have this extension.
          ]

    browserify:
      src:
        src: ['lib/<%= pkg.name %>.js']
        dest: 'build/<%= pkg.name %>.js'
        options:
          #standalone: "Aether"  # can't figure out how to get this to work
          ignore: ['lodash', 'traceur']
      #test:  # We're not using jasmine but now jasmine_node, so we don't need to browserify the tests
      #  src: ['lib/test/*.js']
      #  dest: 'build/test/<%= pkg.name %>_specs.js'

    concat:
      build:
        src: ['node_modules/traceur/bin/traceur.js', 'build/<%= pkg.name %>.js']
        dest: 'build/<%= pkg.name %>.js'

  # Load the plugin that provides the "uglify" task.
  grunt.loadNpmTasks 'grunt-contrib-uglify'
  #grunt.loadNpmTasks 'grunt-contrib-jasmine'
  grunt.loadNpmTasks 'grunt-jasmine-node'
  grunt.loadNpmTasks 'grunt-coffeelint'
  grunt.loadNpmTasks 'grunt-contrib-coffee'
  grunt.loadNpmTasks 'grunt-contrib-watch'
  grunt.loadNpmTasks 'grunt-browserify'
  grunt.loadNpmTasks 'grunt-contrib-concat'
  grunt.loadNpmTasks 'grunt-notify'

  # Default task(s).
  grunt.registerTask 'default', ['coffeelint', 'coffee', 'browserify', 'concat', 'jasmine_node', 'uglify']
  grunt.registerTask 'travis', ['coffeelint', 'coffee', 'browserify', 'concat', 'jasmine_node']
  grunt.registerTask 'build', ['coffeelint', 'coffee', 'browserify', 'concat', 'uglify']
