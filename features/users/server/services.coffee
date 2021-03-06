class @Crater.Services.Core.Account extends @Crater.Services.Core.Base

    MINIMUM_AUTOLOGIN_DAYS = 5

    createUserWithEmail: (doc) ->

        if Meteor.userId()
            return 'LOGGED_IN'

        existingUser = Meteor.users.findOne {
            email: doc.email
        }

        if existingUser
            return 'NOT_UNIQUE_EMAIL'

        result = Accounts.createUser {
            email: doc.email.toLowerCase()
            password: doc.password
            profile:
                firstName: doc.firstName
                lastName: doc.lastName
                active: true
        }

        if not result or not Meteor.users.findOne result
            throw 'NO_USER'

        return result

    verifyPassword: (user, pwd) ->
        pwdDigest = {
            digest: Package.sha.SHA256 (pwd || '')
            algorithm: 'sha-256'
        }

        not Accounts._checkPassword(user, pwdDigest).error

    processLegacyLogin: (email, pwd) ->

        user = Meteor.users.findOne {
            email: email
        }

        if user?.legacy_pwd

            crypto = Meteor.npmRequire 'crypto'
            if crypto.createHash('sha256').update(pwd, 'utf8').digest('hex') is user.legacy_pwd

                Accounts.setPassword user._id, pwd

                user = new MeteorUser user
                user.update {
                    $unset:
                        legacy_pwd: null
                }

                return true

        return false

    updateAccountSettings: (userId, doc) ->
        user = new MeteorUser userId

        user.update {
            $set:
                email: doc.email
                first_name: doc.first_name
                last_name: doc.last_name
                phone: doc.phone
        }

    getNewLoginToken: (userId) ->
        newToken = Accounts._generateStampedLoginToken()
        Accounts._insertLoginToken(userId, newToken)
        newToken.token

    sendNewPasswordLink: (email) ->
        foundUser = new MeteorUser Meteor.users.findOne {
            email: email.toLowerCase()
        }

        if foundUser.anonymous
            return false

        foundUser.update {
            $set:
                password_reset_token: Helpers.Token.GetGuid()
        }

        params = {
            id: foundUser._id
            token: foundUser._user.password_reset_token
        }

        resetUrl = Helpers.Router.Path('presentation.account.reset_password', params, {
                absolute: 1
            })

        emailService = Crater.Services.Get Services.EMAIL
        emailService.SendWithMandrill 'user-pwd-reset', {
            toUser: foundUser
            global_merge_vars: [
                {
                    name: 'firstName'
                    content: foundUser.first_name
                }
                {
                    name: 'resetUrl'
                    content: resetUrl
                }
            ]
        }, foundUser.email

        return true

    setNewUserPassword: (id, token, password) ->

        foundUser = new MeteorUser(Meteor.users.findOne({
            _id: id
            password_reset_token: token
        }))

        if foundUser.anonymous
            throw 'Token not valid'

        Accounts.setPassword id, password

        foundUser.update {
            $unset:
                password_reset_token: null
        }

    sendEmailVerificationRequest: ->

        _user = Meteor.user()

        userType = MeteorUser.GetUserType _user
        user = MeteorUser.GetDefinedUser _user

        user.update {
            $set:
                email_verification_token: Helpers.Token.GetGuid()
        }

        params = {
            token: user._user.email_verification_token
        }

        activationLink = Helpers.Router.Path('presentation.account.verify_email', params, {
            absolute: 1
        })

        template = userType.EMAIL_TEMPLATE_ACTIVATION || 'user-confirm-email'

        emailService = Crater.Services.Get Services.EMAIL
        emailService.SendWithMandrill template, {
            toUser: user
            global_merge_vars: [
                {
                    name: 'firstName'
                    content: user.first_name
                }
                {
                    name: 'activationLink'
                    content:  activationLink
                }
            ]
        }, user.email

    verifyUserEmail: (token) ->

        user = new MeteorUser Meteor.user()

        if user.email_verification_token is token

            Meteor.users.update {
                _id: user._id
                'emails.address': user.email
            }, {
                $set:
                    'emails.$.verified': true
                $unset:
                    email_verification_token: null
            }

            return {
                success: true
            }

        else return false

    uploadNewProfilePicture: (userId, localPath) =>

        @saveOriginal userId, localPath

        @updateProfilePictures userId, localPath, true

    saveOriginal: (userId, localPath) =>
        user = new MeteorUser userId
        logService = Crater.Services.Get Services.LOG
        amazonServices = Crater.Services.Get Services.AMAZON

        extension = Helpers.Server.IO.GetFileExtension(localPath) || 'jpg'
        originalKey =  user.getProfilePicturesBaseFolder() + Math.random() + '_original.' + extension
        logService.Info 'Uploading original picture to CDN'
        Meteor.wrapAsync(amazonServices.uploadFile) localPath, originalKey, null

        user.update {
            $set:
                'pictures.original': originalKey
        }

        user.pictures

    ensurePostSignupOps: (userId) =>
        user = new MeteorUser userId

        if not user.platform?.post_signup_executed
            @updateProfilePictures userId

            @ensureLocation userId

            user.update {
                $set:
                    'platform.post_signup_executed': true
            }


    updateProfilePictures: (userId, localPath, forceRegeneration, cropData) =>

        logService = Crater.Services.Get Services.LOG
        amazonServices = Crater.Services.Get Services.AMAZON
        user = new MeteorUser userId

        baseFolder = user.getProfilePicturesBaseFolder()

        pictures = user.pictures || {}

        # Finding out which resolutions we have to store
        resolutionsToStore = []
        for own key, resolution of Crater.Users.PictureSizes
            resolutionsToStore.push(resolution) if not pictures[user.getProfilePictureKey(resolution)] or forceRegeneration

        # If we have to generate any picture
        if resolutionsToStore.length

            logService.Info 'Must generate pictures for user ' + user._id

            if not localPath
                # Downloading original picture from source
                if not pictures.original
                    logService.Info 'Getting original picture Url'
                    pictureOriginal = user.getProfilePictureOriginal()

                    if pictureOriginal
                        extension = Helpers.Server.IO.GetFileExtension(pictureOriginal) || 'jpg'
                        logService.Info 'Downloading original picture: ' + pictureOriginal
                        localPath = Meteor.wrapAsync(Helpers.Server.Communication.GetFile) pictureOriginal, 'profilePicture' + user._id + '.' + extension, false

                        pictures = @saveOriginal userId, localPath
                # Downloading original picture from CDN
                else
                    extension = Helpers.Server.IO.GetFileExtension(pictures.original) || 'jpg'
                    logService.Info 'Downloading original picture from CDN'
                    originalUrl = Helpers.Amazon.GetBucketUrl pictures.original
                    logService.Info 'Original CDN Url: ' + originalUrl
                    localPath = Meteor.wrapAsync(Helpers.Server.Communication.GetFile) originalUrl, 'profilePicture' + user._id + '.' + extension, false

            if localPath

                uniqueKey = Helpers.Token.GetGuid()

                extension = Helpers.Server.IO.GetFileExtension(localPath) || 'jpg'

                for resolution in resolutionsToStore

                    resizedFile = localPath + resolution.toString() + '_' + uniqueKey + '.' + extension
                    resizedName = user.getProfilePictureKey(resolution)
                    resizedKey = baseFolder + resolution + '_' + uniqueKey + '.' + extension

                    Meteor.wrapAsync(Helpers.Server.Image.Resize) {
                        source: localPath
                        destination: resizedFile
                        width: resolution
                        crop: cropData
                    }

                    Meteor.wrapAsync(amazonServices.uploadFile) resizedFile, resizedKey, null
                    pictures[resizedName] = resizedKey
                    Helpers.Server.IO.DeleteFile resizedFile


                # If we do have an original picture
                if localPath
                    # Deleting original picture
                    Helpers.Server.IO.DeleteFile localPath
            else
                console.log 'No profile picture'

            user.updateProfilePictures pictures
        else
            logService.Info 'No need to generate pictures for ' + user._id

    ensureLocation: (userId) ->
        user = new MeteorUser userId

        userIp = Helpers.Server.Auth.GetCurrentConnection()?.clientAddress

        if Meteor.settings.local
            userIp = '62.157.63.1'

        try
            geoData = EJSON.parse(Helpers.Server.Communication.GetPage 'http://freegeoip.net/json/' + userIp)

            formattedName = ''

            if geoData.city
                formattedName = geoData.city + ', ' + geoData.country_name

            user.update {
                $set:
                    ip: userIp
                    location: {
                        formatted_name: formattedName
                        country_code: geoData.country_code
                        country_name: geoData.country_name
                        region: geoData.region_name
                        zip: geoData.zip_code
                        lat: geoData.latitude
                        lon: geoData.longitude
                    }
            }
        catch e
            if Meteor.settings.local
                throw e

    updateUserLocationFromGoogle: (userId, place) ->

        user = new MeteorUser userId

        country = place.address_components?[place.address_components?.length - 1]

        user.update {
            $set:
                location: _.extend {
                    formatted_name: place.formatted_address
                    country_code: country?.short_name
                    country_code: country?.long_name
                }, Helpers.Google.GetLatLonFromLocation place.geometry?.location
        }

    getUserAutologinTokenSuffix: (user, durationInDays) =>
        token = @getUserAutologinToken user, durationInDays
        'autologin_userid=' + user._id + '&autologin_token=' + token

    getUserAutologinToken: (user, durationInDays) ->

        # Disabling ES
        _esStatus = Meteor.settings.elasticsearch.disable
        Meteor.settings.elasticsearch.disable = true

        if typeof user is 'string'
            user = new MeteorUser user
        else
            user = new MeteorUser user

        expiryDate = (new Date()).addDays(durationInDays).resetTime()
        mustUpdate = false

        # Refreshing existing tokens
        autoLoginsToKeep = []
        now = (new Date()).resetTime()
        for autoLogin in user.auto_logins || []
            if autoLogin.expires - now > 0
                autoLoginsToKeep.push autoLogin
            else # removing stuff - must update
                mustUpdate = true

        # New token
        loginToken = _.find autoLoginsToKeep, (a) ->
            (a.expires - new Date()) >= MINIMUM_AUTOLOGIN_DAYS

        if not loginToken
            loginToken = {
                expires: expiryDate
                token: Helpers.Token.GetGuid()
            }
            autoLoginsToKeep.push loginToken
            mustUpdate = true

            console.log user.getName() + ' just got an autologin'

        if mustUpdate
            user.update {
                $set:
                    auto_logins: autoLoginsToKeep
            }, {
                silent: true
            }

        # Re-enabling ES
        Meteor.settings.elasticsearch.disable = _esStatus

        loginToken.token

    autoLogin: (userId, token) -> # Must be called passing the current context because of the setUserId functionality
        user = new MeteorUser userId

        authorized = false
        for autoLogin in user.auto_logins || []
            if autoLogin.token is token
                authorized = true
                break

        if authorized
            accountService = Crater.Services.Get Services.ACCOUNT
            newToken = accountService.getNewLoginToken(userId)

            @setUserId userId

            {
            userId: userId
            token: newToken
            expires: (new Date()).addDays(60)
            }

    exportToIntercom: (users) =>
        if Meteor.settings.intercom.disable
            console.log 'Disabled'
            return

        intercomClient = Helpers.Analytics.GetIntercomClient()
        logServices = Crater.Services.Get Services.LOG

        users = users || Meteor.users.find().fetch()

        userChunks = users.splitIntoChunks(100)

        exportChunk = =>
            userChunk = userChunks.pop()

            if userChunk

                logServices.Info 'Exporting ' + userChunk.length

                usersData = _.map(userChunk, (user) =>
                    user = new MeteorUser user
                    data = user.getTrackingForIntercom()
                    data.custom_attributes.autoLoginSuffix = @getUserAutologinTokenSuffix(user, MINIMUM_AUTOLOGIN_DAYS)

                    {
                    create: data
                    }
                )
                
                result = Meteor.wrapAsync((callback) ->
                    intercomClient.users.bulk(usersData, (err, content) ->
                        callback(err, content)
                    )
                )()

                if result.ok
                    logServices.Info 'Exported'
                    userIds = _.map usersData, (u) -> u.create.user_id

                    Meteor.users.update {
                        _id:
                            $in: userIds
                        'platform.tracked_on_intercom':
                            $ne: true
                    }, {
                        $set:
                            'platform.tracked_on_intercom': true
                    }, {
                        multi: true
                    }

                exportChunk()

        exportChunk()

        readChunk = (pages) ->

            console.log 'Re-reading chunk', pages

            # Refreshing users
            intercomClient = Helpers.Analytics.GetIntercomClient()

            response = Meteor.wrapAsync((callback) ->

                if pages
                    intercomClient.nextPage pages, (err, content) ->
                        callback(err, content)
                else
                    intercomClient.users.list((err, content) ->
                        callback(err, content)
                    )
            )()

            if response.body?.users?.length
                for user in response.body.users
                    Meteor.users.update user.user_id, {
                        $set:
                            'platform.intercom_id': user.id
                    }

                if response.body.pages
                    readChunk(response.body.pages)

        usersWithoutIntercom = Meteor.users.find({
            'platform.intercom_id':
                $exists: false
        }).fetch()

        logServices.Info 'Users without Intercom ID: ' + usersWithoutIntercom.length
        if usersWithoutIntercom.length > 100
            readChunk()
        else
            for user in usersWithoutIntercom
                user = new MeteorUser user
                user.updateIntercomId()



    exportToCsv: (properties) ->

        projection = _.extend {}, properties.fields || {}

        if properties.autoLogin
            projection.auto_logins = true

        users = Meteor.users.find(properties.filters || {}, {
            fields: projection
            sort: properties.sort || {
                first_name: 1
                last_name: 1
            }
        }).fetch()

        csv = []

        for user in users

            user = new MeteorUser user

            userData = []

            for key, value of properties.fields
                userData.push (Object.byString(user, key) || '').toString()

            if properties.autoLogin
                userData.push @getUserAutologinTokenSuffix user, 10

            userData.push user.isVerified()
            userData.push user.getUrl()

            userData = _.map userData, (d) ->
                '"' + (d || '').toString().replace(/"/g, '""') + '"'

            csv.push userData

        csv.join '\n'

    updateRecent: (all) =>
        logService = Crater.Services.Get Services.LOG

        updatedUsers = null
        if all
            updatedUsers = Meteor.users.find().fetch()
        else
            # Getting created or updated users since startDate
            startDate = (new Date()).addSeconds(- 60 * 60) # 1 hours
            updatedUsers = Meteor.users.find({
                $or: [
                    {
                        createdAt: {
                            $gte: startDate
                        }
                    }
                    {
                        updatedAt: {
                            $gte: startDate
                        }
                    }
                ]
            }).fetch()

        logService.Info updatedUsers.length, 'users to update'

        # Intercom
        @exportToIntercom updatedUsers

        # Elastic Search
        esServices = Crater.Services.Get Services.ELASTIC_SEARCH
        esServices.pushUsers updatedUsers

        logService.Info 'Uploading', updatedUsers.length, ' to Highrise'

        for user in updatedUsers
            user = MeteorUser.GetDefinedUser user

            # Highrise
            if MeteorUser.GetUserType(user).PushToHighrise
                user.updateHighrise()

        logService.Info 'Finished'

@Services.ACCOUNT =
    key: 'account'
    service: -> new Crater.Services.Core.Account()

@Crater.Services.Set(@Services.ACCOUNT)

@Crater.Users.PostSignupServices.push Services.ACCOUNT
