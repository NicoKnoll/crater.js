ironRouter = Router
ironRouteController = RouteController

class @Helpers.Router

    routes = []

    setBodyLayout = (layout) ->
        body = $ document.body

        if body.attr 'data-layout-class'
            body.removeClass body.attr 'data-layout-class'

        classes = 'layout-' + layout

        # adding current mapping
        classes += ' ' + (Router.current?()?.route?.getName() || '')

        # adding current roles
        for role in Roles.getRolesForUser Meteor.userId()
            classes += ' ' + 'role-' + role

        body.addClass classes
        body.attr 'data-layout-class', classes

    @Path: (route, params, options) =>
        route.path params, options

    @AddRoute: (route) =>
        routes.push route

    @SetRoute: (route) =>

        path = '/' + route.path
        title = route.title
        delete route.title
        delete route.path

        route.controller = route.controller.controller

        action = route.action

        route.action = ->
            if @ready()
                @layout route.controller.layout

                if title
                    Helpers.Client.SEO.SetTitle title()
                else
                    Helpers.Client.SEO.SetTitle GlobalSettings.companyName

                action.apply @
            else
                @layout 'loader'
                @render 'loading'

        ironRouter.route path, route

    @AddController: (controller) =>

        originalOnAfterAction = controller.onAfterAction
        originalOnBeforeAction = controller.onBeforeAction
        layout = controller.layoutTemplate
        delete controller.layoutTemplate

        if Meteor.isClient
            originalWaitOn = controller.waitOn

            controller.onBeforeAction = ->

                if originalOnBeforeAction
                    return originalOnBeforeAction.apply @

                @next()

            controller.waitOn = =>
                retVal = []

                if originalWaitOn
                    retVal = originalWaitOn()

                retVal.push ReactivePromise.when("craterStarted", Crater._startedDeferred.promise());
                retVal.push Meteor.subscribe('translations', Helpers.Translation.GetUserLanguage(), ironRouter.current().route.getName())

                retVal

        ret = ironRouteController.extend _.extend(controller, {
            onAfterAction: =>
                setBodyLayout controller.name

                if originalOnAfterAction
                    originalOnAfterAction()
        })

        ret.layout = layout
        ret

    @Init: =>
        for route in routes
            @SetRoute route