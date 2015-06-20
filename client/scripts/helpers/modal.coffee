class @Helpers.Client.Modal

    @Show: (options) ->
        $('#' + options.identifier).modal {
            show: true
            backdrop: 'static'
            keyboard: true
        }

    @Close: ->
        $('.modal.fade.in').modal 'hide'