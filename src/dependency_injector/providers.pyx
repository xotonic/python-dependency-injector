"""Dependency injector providers.

Powered by Cython.
"""


import copy
import sys
import types
import threading

try:
    import asyncio
except ImportError:
    asyncio = None
    _is_coroutine_marker = None
else:
    if sys.version_info >= (3, 5, 3):
        import asyncio.coroutines
        _is_coroutine_marker = asyncio.coroutines._is_coroutine
    else:
        _is_coroutine_marker = True


from .errors import (
    Error,
    NoSuchProviderError,
)

cimport cython


if sys.version_info[0] == 3:  # pragma: no cover
    CLASS_TYPES = (type,)
else:  # pragma: no cover
    CLASS_TYPES = (type, types.ClassType)

    copy._deepcopy_dispatch[types.MethodType] = \
        lambda obj, memo: type(obj)(obj.im_func,
                                    copy.deepcopy(obj.im_self, memo),
                                    obj.im_class)


cdef class Provider(object):
    """Base provider class.

    :py:class:`Provider` is callable (implements ``__call__`` method). Every
    call to provider object returns provided result, according to the providing
    strategy of particular provider. This ``callable`` functionality is a
    regular part of providers API and it should be the same for all provider's
    subclasses.

    Implementation of particular providing strategy should be done in
    :py:meth:`Provider._provide` of :py:class:`Provider` subclass. Current
    method is called every time when not overridden provider is called.

    :py:class:`Provider` implements provider overriding logic that should be
    also common for all providers:

    .. code-block:: python

        provider1 = Factory(SomeClass)
        provider2 = Factory(ChildSomeClass)

        provider1.override(provider2)

        some_instance = provider1()
        assert isinstance(some_instance, ChildSomeClass)

    Also :py:class:`Provider` implements helper function for creating its
    delegates:

    .. code-block:: python

        provider = Factory(object)
        delegate = provider.delegate()

        delegated = delegate()

        assert provider is delegated

    All providers should extend this class.

    .. py:attribute:: overridden

        Tuple of overriding providers, if any.

        :type: tuple[:py:class:`Provider`] | None
    """

    __IS_PROVIDER__ = True

    overriding_lock = threading.RLock()
    """Overriding reentrant lock.

    :type: :py:class:`threading.RLock`
    """

    def __init__(self):
        """Initializer."""
        self.__overridden = tuple()
        self.__last_overriding = None
        super(Provider, self).__init__()

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is not None:
            return self.__last_overriding(*args, **kwargs)
        return self._provide(args, kwargs)

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = self.__class__()

        self._copy_overridings(copied, memo)

        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=None)

    def __repr__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return self.__str__()

    @property
    def overridden(self):
        """Return tuple of overriding providers."""
        with self.overriding_lock:
            return self.__overridden

    @property
    def last_overriding(self):
        """Return last overriding provider.

        If provider is not overridden, then None is returned.
        """
        return self.__last_overriding

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if provider is self:
            raise Error('Provider {0} could not be overridden '
                        'with itself'.format(self))

        if not is_provider(provider):
            provider = Object(provider)

        with self.overriding_lock:
            self.__overridden += (provider,)
            self.__last_overriding = provider

        return OverridingContext(self, provider)

    def reset_last_overriding(self):
        """Reset last overriding provider.

        :raise: :py:exc:`dependency_injector.errors.Error` if provider is not
                overridden.

        :rtype: None
        """
        with self.overriding_lock:
            if len(self.__overridden) == 0:
                raise Error('Provider {0} is not overridden'.format(str(self)))

            self.__overridden = self.__overridden[:-1]
            try:
                self.__last_overriding = self.__overridden[-1]
            except IndexError:
                self.__last_overriding = None

    def reset_override(self):
        """Reset all overriding providers.

        :rtype: None
        """
        with self.overriding_lock:
            self.__overridden = tuple()
            self.__last_overriding = None

    def delegate(self):
        """Return provider's delegate.

        :rtype: :py:class:`Delegate`
        """
        return Delegate(self)

    @property
    def provider(self):
        """Return provider's delegate.

        :rtype: :py:class:`Delegate`
        """
        return self.delegate()

    cpdef object _provide(self, tuple args, dict kwargs):
        """Providing strategy implementation.

        Abstract protected method that implements providing strategy of
        particular provider. Current method is called every time when not
        overridden provider is called. Need to be overridden in subclasses.
        """
        raise NotImplementedError()

    cpdef void _copy_overridings(self, Provider copied, dict memo):
        """Copy provider overridings to a newly copied provider."""
        copied.__overridden = deepcopy(self.__overridden, memo)
        copied.__last_overriding = deepcopy(self.__last_overriding, memo)


cdef class Object(Provider):
    """Object provider returns provided instance "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, provides):
        """Initializer.

        :param provides: Value that have to be provided.
        :type provides: object
        """
        self.__provides = provides
        super(Object, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = self.__class__(deepcopy(self.__provides, memo))

        self._copy_overridings(copied, memo)

        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.__provides)

    def __repr__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return self.__str__()

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return provided instance.

        :param args: Tuple of context positional arguments.
        :type args: tuple[object]

        :param kwargs: Dictionary of context keyword arguments.
        :type kwargs: dict[str, object]

        :rtype: object
        """
        return self.__provides


cdef class Delegate(Object):
    """Delegate provider returns provider "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, provides):
        """Initializer.

        :param provides: Value that have to be provided.
        :type provides: object
        """
        super(Delegate, self).__init__(ensure_is_provider(provides))


cdef class Dependency(Provider):
    """:py:class:`Dependency` provider describes dependency interface.

    This provider is used for description of dependency interface. That might
    be useful when dependency could be provided in the client's code only,
    but it's interface is known. Such situations could happen when required
    dependency has non-determenistic list of dependencies itself.

    .. code-block:: python

        database_provider = Dependency(sqlite3.dbapi2.Connection)
        database_provider.override(Factory(sqlite3.connect, ':memory:'))

        database = database_provider()

    .. py:attribute:: instance_of

        Class of required dependency.

        :type: type
   """

    def __init__(self, type instance_of=object):
        """Initializer."""
        self.__instance_of = instance_of
        super(Dependency, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = self.__class__(self.__instance_of)

        self._copy_overridings(copied, memo)

        return copied

    def __call__(self, *args, **kwargs):
        """Return provided instance.

        :raise: :py:exc:`dependency_injector.errors.Error`

        :rtype: object
        """
        cdef object instance

        if self.__last_overriding is None:
            raise Error('Dependency is not defined')

        instance = self.__last_overriding(*args, **kwargs)

        if not isinstance(instance, self.instance_of):
            raise Error('{0} is not an '.format(instance) +
                        'instance of {0}'.format(self.instance_of))

        return instance

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.__instance_of)

    def __repr__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return self.__str__()

    @property
    def instance_of(self):
        """Return class of required dependency."""
        return self.__instance_of

    def provided_by(self, provider):
        """Set external dependency provider.

        :param provider: Provider that provides required dependency.
        :type provider: :py:class:`Provider`

        :rtype: None
        """
        return self.override(provider)


cdef class ExternalDependency(Dependency):
    """:py:class:`ExternalDependency` provider describes dependency interface.

    This provider is used for description of dependency interface. That might
    be useful when dependency could be provided in the client's code only,
    but it's interface is known. Such situations could happen when required
    dependency has non-determenistic list of dependencies itself.

    .. code-block:: python

        database_provider = ExternalDependency(sqlite3.dbapi2.Connection)
        database_provider.override(Factory(sqlite3.connect, ':memory:'))

        database = database_provider()

    .. deprecated:: 3.9

        Use :py:class:`Dependency` instead.

    .. py:attribute:: instance_of

        Class of required dependency.

        :type: type
    """


cdef class DependenciesContainer(Object):
    """:py:class:`DependenciesContainer` provider provides set of dependencies.


    Dependencies container provider is used to implement late static binding
    for a set of providers of a particular container.

    Example code:

    .. code-block:: python

        class Adapters(containers.DeclarativeContainer):
            email_sender = providers.Singleton(SmtpEmailSender)

        class TestAdapters(containers.DeclarativeContainer):
            email_sender = providers.Singleton(EchoEmailSender)

        class UseCases(containers.DeclarativeContainer):
            adapters = providers.DependenciesContainer()

            signup = providers.Factory(SignupUseCase,
                                       email_sender=adapters.email_sender)

        use_cases = UseCases(adapters=Adapters)
        # or
        use_cases = UseCases(adapters=TestAdapters)

        # Another file
        from .containers import use_cases

        use_case = use_cases.signup()
        use_case.execute()
    """

    def __init__(self, provides=None, **dependencies):
        """Initializer."""
        self.__providers = dependencies

        if provides:
            self._override_providers(container=provides)

        super(DependenciesContainer, self).__init__(provides)

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        cdef DependenciesContainer copied

        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = self.__class__()
        copied.__provides = deepcopy(self.__provides, memo)
        copied.__providers = deepcopy(self.__providers, memo)

        self._copy_overridings(copied, memo)

        return copied

    def __getattr__(self, name):
        """Return dependency provider."""
        if name.startswith('__') and name.endswith('__'):
            raise AttributeError(
                '\'{cls}\' object has no attribute '
                '\'{attribute_name}\''.format(cls=self.__class__.__name__,
                                              attribute_name=name))

        provider = self.__providers.get(name)
        if not provider:
            provider = Dependency()
            self.__providers[name] = provider

            container = self.__call__()
            if container:
                dependency_provider = container.providers.get(name)
                if dependency_provider:
                    provider.override(dependency_provider)

        return provider

    @property
    def providers(self):
        """Read-only dictionary of dependency providers."""
        return self.__providers

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        self._override_providers(container=provider)
        return super(DependenciesContainer, self).override(provider)

    def reset_last_overriding(self):
        """Reset last overriding provider.

        :raise: :py:exc:`dependency_injector.errors.Error` if provider is not
                overridden.

        :rtype: None
        """
        for child in self.__providers.values():
            try:
                child.reset_last_overriding()
            except Error:
                pass
        super(DependenciesContainer, self).reset_last_overriding()

    def reset_override(self):
        """Reset all overriding providers.

        :rtype: None
        """
        for child in self.__providers.values():
            child.reset_override()
        super(DependenciesContainer, self).reset_override()

    cpdef object _override_providers(self, object container):
        """Override providers with providers from provided container."""
        for name, dependency_provider in container.providers.items():
            provider = self.__providers.get(name)

            if not provider:
                continue

            if provider.last_overriding is dependency_provider:
                continue

            provider.override(dependency_provider)


cdef class OverridingContext(object):
    """Provider overriding context.

    :py:class:`OverridingContext` is used by :py:meth:`Provider.override` for
    implemeting ``with`` contexts. When :py:class:`OverridingContext` is
    closed, overriding that was created in this context is dropped also.

    .. code-block:: python

        with provider.override(another_provider):
            assert provider.overridden
        assert not provider.overridden
    """

    def __init__(self, Provider overridden, Provider overriding):
        """Initializer.

        :param overridden: Overridden provider.
        :type overridden: :py:class:`Provider`

        :param overriding: Overriding provider.
        :type overriding: :py:class:`Provider`
        """
        self.__overridden = overridden
        self.__overriding = overriding
        super(OverridingContext, self).__init__()

    def __enter__(self):
        """Do nothing."""
        return self.__overriding

    def __exit__(self, *_):
        """Exit overriding context."""
        self.__overridden.reset_last_overriding()


cdef class Callable(Provider):
    r"""Callable provider calls wrapped callable on every call.

    Callable supports positional and keyword argument injections:

    .. code-block:: python

        some_function = Callable(some_function,
                                 'positional_arg1', 'positional_arg2',
                                 keyword_argument1=3, keyword_argument=4)

        # or

        some_function = Callable(some_function) \
            .add_args('positional_arg1', 'positional_arg2') \
            .add_kwargs(keyword_argument1=3, keyword_argument=4)

        # or

        some_function = Callable(some_function)
        some_function.add_args('positional_arg1', 'positional_arg2')
        some_function.add_kwargs(keyword_argument1=3, keyword_argument=4)
    """

    def __init__(self, provides, *args, **kwargs):
        """Initializer.

        :param provides: Wrapped callable.
        :type provides: callable
        """
        if not callable(provides):
            raise Error('Provider {0} expected to get callable, '
                        'got {0}'.format('.'.join((self.__class__.__module__,
                                                   self.__class__.__name__)),
                                         provides))
        self.__provides = provides

        self.__args = tuple()
        self.__args_len = 0
        self.set_args(*args)

        self.__kwargs = tuple()
        self.__kwargs_len = 0
        self.set_kwargs(**kwargs)

        super(Callable, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        provides = self.provides
        if isinstance(provides, Provider):
            provides = deepcopy(provides, memo)

        copied = self.__class__(provides,
                                *deepcopy(self.args, memo),
                                **deepcopy(self.kwargs, memo))

        self._copy_overridings(copied, memo)

        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.__provides)

    @property
    def provides(self):
        """Return wrapped callable."""
        return self.__provides

    @property
    def args(self):
        """Return positional argument injections."""
        cdef int index
        cdef PositionalInjection arg
        cdef list args

        args = list()
        for index in range(self.__args_len):
            arg = self.__args[index]
            args.append(arg.__value)
        return tuple(args)

    def add_args(self, *args):
        """Add positional argument injections.

        :return: Reference ``self``
        """
        self.__args += parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    def set_args(self, *args):
        """Set postional argument injections.

        Existing positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__args = parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    def clear_args(self):
        """Drop postional argument injections.

        :return: Reference ``self``
        """
        self.__args = tuple()
        self.__args_len = len(self.__args)
        return self

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        cdef int index
        cdef NamedInjection kwarg
        cdef dict kwargs

        kwargs = dict()
        for index in range(self.__kwargs_len):
            kwarg = self.__kwargs[index]
            kwargs[kwarg.__name] = kwarg.__value
        return kwargs

    def add_kwargs(self, **kwargs):
        """Add keyword argument injections.

        :return: Reference ``self``
        """
        self.__kwargs += parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)
        return self

    def set_kwargs(self, **kwargs):
        """Set keyword argument injections.

        Existing keyword argument injections are dropped.

        :return: Reference ``self``
        """
        self.__kwargs = parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)
        return self

    def clear_kwargs(self):
        """Drop keyword argument injections.

        :return: Reference ``self``
        """
        self.__kwargs = tuple()
        self.__kwargs_len = len(self.__kwargs)
        return self

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable's call."""
        return __callable_call(self, args, kwargs)


cdef class DelegatedCallable(Callable):
    """Callable that is injected "as is".

    DelegatedCallable is a :py:class:`Callable`, that is injected "as is".
    """

    __IS_DELEGATED__ = True


cdef class AbstractCallable(Callable):
    """Abstract callable provider.

    :py:class:`AbstractCallable` is a :py:class:`Callable` provider that must
    be explicitly overridden before calling.

    Overriding of :py:class:`AbstractCallable` is possible only by another
    :py:class:`Callable` provider.
    """

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is None:
            raise Error('{0} must be overridden before calling'.format(self))
        return self.__last_overriding(*args, **kwargs)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if not isinstance(provider, Callable):
            raise Error('{0} must be overridden only by '
                        '{1} providers'.format(self, Callable))
        return super(AbstractCallable, self).override(provider)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable's call."""
        raise NotImplementedError('Abstract provider forward providing logic '
                                  'to overriding provider')


cdef class CallableDelegate(Delegate):
    """Callable delegate injects delegating callable "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, callable):
        """Initializer.

        :param callable: Value that have to be provided.
        :type callable: object
        """
        if isinstance(callable, Callable) is False:
            raise Error('{0} can wrap only {1} providers'.format(
                self.__class__, Callable))
        super(Delegate, self).__init__(callable)


cdef class Coroutine(Callable):
    r"""Coroutine provider creates wrapped coroutine on every call.

    Coroutine supports positional and keyword argument injections:

    .. code-block:: python

        some_coroutine = Coroutine(some_coroutine,
                                   'positional_arg1', 'positional_arg2',
                                   keyword_argument1=3, keyword_argument=4)

        # or

        some_coroutine = Coroutine(some_coroutine) \
            .add_args('positional_arg1', 'positional_arg2') \
            .add_kwargs(keyword_argument1=3, keyword_argument=4)

        # or

        some_coroutine = Coroutine(some_coroutine)
        some_coroutine.add_args('positional_arg1', 'positional_arg2')
        some_coroutine.add_kwargs(keyword_argument1=3, keyword_argument=4)
    """

    _is_coroutine = _is_coroutine_marker

    def __init__(self, provides, *args, **kwargs):
        """Initializer.

        :param provides: Wrapped callable.
        :type provides: callable
        """
        if not asyncio:
            raise Error('Package asyncio is not available')

        if not asyncio.iscoroutinefunction(provides):
            raise Error('Provider {0} expected to get coroutine function, '
                        'got {1}'.format('.'.join((self.__class__.__module__,
                                                   self.__class__.__name__)),
                                         provides))

        super(Coroutine, self).__init__(provides, *args, **kwargs)


cdef class DelegatedCoroutine(Coroutine):
    """Coroutine provider that is injected "as is".

    DelegatedCoroutine is a :py:class:`Coroutine`, that is injected "as is".
    """

    __IS_DELEGATED__ = True


cdef class AbstractCoroutine(Coroutine):
    """Abstract coroutine provider.

    :py:class:`AbstractCoroutine` is a :py:class:`Coroutine` provider that must
    be explicitly overridden before calling.

    Overriding of :py:class:`AbstractCoroutine` is possible only by another
    :py:class:`Coroutine` provider.
    """

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is None:
            raise Error('{0} must be overridden before calling'.format(self))
        return self.__last_overriding(*args, **kwargs)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if not isinstance(provider, Coroutine):
            raise Error('{0} must be overridden only by '
                        '{1} providers'.format(self, Coroutine))
        return super(AbstractCoroutine, self).override(provider)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable's call."""
        raise NotImplementedError('Abstract provider forward providing logic '
                                  'to overriding provider')


cdef class CoroutineDelegate(Delegate):
    """Coroutine delegate injects delegating coroutine "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, coroutine):
        """Initializer.

        :param coroutine: Value that have to be provided.
        :type coroutine: object
        """
        if isinstance(coroutine, Coroutine) is False:
            raise Error('{0} can wrap only {1} providers'.format(
                self.__class__, Callable))
        super(CoroutineDelegate, self).__init__(coroutine)


cdef class Configuration(Object):
    """Configuration provider.

    Configuration provider helps with implementing late static binding of
    configuration options - use first, define later.

    .. code-block:: python

        config = Configuration('config')

        print(config.section1.option1())  # None
        print(config.section1.option2())  # None

        config.override({'section1': {'option1': 1,
                                      'option2': 2}})

        print(config.section1.option1())  # 1
        print(config.section1.option2())  # 2
    """

    def __init__(self, name, default=None):
        """Initializer.

        :param name: Name of configuration unit.
        :type name: str

        :param default: Default values of configuration unit.
        :type default: dict
        """
        super(Configuration, self).__init__(default)

        self.__name = name
        self.__children = self._create_children(default)

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        cdef Configuration copied

        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = self.__class__(self.__name)
        copied.__provides = deepcopy(self.__provides, memo)
        copied.__children = deepcopy(self.__children, memo)

        self._copy_overridings(copied, memo)

        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.__name)

    def __getattr__(self, str name):
        """Return child configuration provider."""
        if name.startswith('__') and name.endswith('__'):
            raise AttributeError(
                '\'{cls}\' object has no attribute '
                '\'{attribute_name}\''.format(cls=self.__class__.__name__,
                                              attribute_name=name))

        child_provider = self.__children.get(name)

        if child_provider is None:
            child_name = self._get_child_full_name(name)
            child_provider = self.__class__(child_name)

            value = self.__call__()
            if isinstance(value, dict):
                child_value = value.get(name)
                child_provider.override(child_value)

            self.__children[name] = child_provider

        return child_provider

    def get_name(self):
        """Name of configuration unit."""
        return self.__name

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        overriding_context = super(Configuration, self).override(provider)

        value = self.__call__()
        if not isinstance(value, dict):
            return

        for name in value:
            child_provider = self.__children.get(name)
            if child_provider is None:
                continue
            child_provider.override(value.get(name))

        return overriding_context

    def reset_last_overriding(self):
        """Reset last overriding provider.

        :raise: :py:exc:`dependency_injector.errors.Error` if provider is not
                overridden.

        :rtype: None
        """
        for child in self.__children.values():
            try:
                child.reset_last_overriding()
            except Error:
                pass
        super(Configuration, self).reset_last_overriding()

    def reset_override(self):
        """Reset all overriding providers.

        :rtype: None
        """
        for child in self.__children.values():
            child.reset_override()
        super(Configuration, self).reset_override()

    def update(self, value):
        """Set configuration options.

        .. deprecated:: 3.11

            Use :py:meth:`Configuration.override` instead.

        :param value: Value of configuration option.
        :type value: object | dict

        :rtype: None
        """
        self.override(value)

    def _create_children(self, value):
        children = dict()

        if not isinstance(value, dict):
            return children

        for child_name, child_value in value.items():
            child_full_name = self._get_child_full_name(child_name)
            child_provider = self.__class__(child_full_name, child_value)
            children[child_name] = child_provider

        return children

    def _get_child_full_name(self, child_name):
        child_full_name = ''

        if self.__name:
            child_full_name += self.__name + '.'
        child_full_name += child_name

        return child_full_name


cdef class Factory(Provider):
    r"""Factory provider creates new instance on every call.

    :py:class:`Factory` supports positional & keyword argument injections,
    as well as attribute injections.

    Positional and keyword argument injections could be defined like this:

    .. code-block:: python

        factory = Factory(SomeClass,
                          'positional_arg1', 'positional_arg2',
                          keyword_argument1=3, keyword_argument=4)

        # or

        factory = Factory(SomeClass) \
            .add_args('positional_arg1', 'positional_arg2') \
            .add_kwargs(keyword_argument1=3, keyword_argument=4)

        # or

        factory = Factory(SomeClass)
        factory.add_args('positional_arg1', 'positional_arg2')
        factory.add_kwargs(keyword_argument1=3, keyword_argument=4)


    Attribute injections are defined by using
    :py:meth:`Factory.add_attributes`:

    .. code-block:: python

        factory = Factory(SomeClass) \
            .add_attributes(attribute1=1, attribute2=2)

    Retrieving of provided instance can be performed via calling
    :py:class:`Factory` object:

    .. code-block:: python

        factory = Factory(SomeClass)
        some_object = factory()

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None
    """

    provided_type = None

    def __init__(self, provides, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        if (self.__class__.provided_type and
                not issubclass(provides, self.__class__.provided_type)):
            raise Error('{0} can provide only {1} instances'.format(
                self.__class__, self.__class__.provided_type))

        self.__instantiator = Callable(provides, *args, **kwargs)

        self.__attributes = tuple()
        self.__attributes_len = 0

        super(Factory, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        cls = self.cls
        if isinstance(cls, Provider):
            cls = deepcopy(cls, memo)

        copied = self.__class__(cls,
                                *deepcopy(self.args, memo),
                                **deepcopy(self.kwargs, memo))
        copied.set_attributes(**deepcopy(self.attributes, memo))

        self._copy_overridings(copied, memo)

        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self,
                                  provides=self.__instantiator.provides)

    @property
    def cls(self):
        """Return provided type."""
        return self.__instantiator.provides

    @property
    def args(self):
        """Return positional argument injections."""
        return self.__instantiator.args

    def add_args(self, *args):
        """Add __init__ postional argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_args(*args)
        return self

    def set_args(self, *args):
        """Set __init__ postional argument injections.

        Existing __init__ positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_args(*args)
        return self

    def clear_args(self):
        """Drop __init__ postional argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_args()
        return self

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        return self.__instantiator.kwargs

    def add_kwargs(self, **kwargs):
        """Add __init__ keyword argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_kwargs(**kwargs)
        return self

    def set_kwargs(self, **kwargs):
        """Set __init__ keyword argument injections.

        Existing __init__ keyword argument injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_kwargs(**kwargs)
        return self

    def clear_kwargs(self):
        """Drop __init__ keyword argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_kwargs()
        return self

    @property
    def attributes(self):
        """Return attribute injections."""
        cdef int index
        cdef NamedInjection attribute
        cdef dict attributes

        attributes = dict()
        for index in range(self.__attributes_len):
            attribute = self.__attributes[index]
            attributes[attribute.__name] = attribute.__value
        return attributes

    def add_attributes(self, **kwargs):
        """Add attribute injections.

        :return: Reference ``self``
        """
        self.__attributes += parse_named_injections(kwargs)
        self.__attributes_len = len(self.__attributes)
        return self

    def set_attributes(self, **kwargs):
        """Set attribute injections.

        Existing attribute injections are dropped.

        :return: Reference ``self``
        """
        self.__attributes = parse_named_injections(kwargs)
        self.__attributes_len = len(self.__attributes)
        return self

    def clear_attributes(self):
        """Drop attribute injections.

        :return: Reference ``self``
        """
        self.__attributes = tuple()
        self.__attributes_len = len(self.__attributes)
        return self

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return new instance."""
        return __factory_call(self, args, kwargs)


cdef class DelegatedFactory(Factory):
    """Factory that is injected "as is".

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    __IS_DELEGATED__ = True


cdef class AbstractFactory(Factory):
    """Abstract factory provider.

    :py:class:`AbstractFactory` is a :py:class:`Factory` provider that must
    be explicitly overridden before calling.

    Overriding of :py:class:`AbstractFactory` is possible only by another
    :py:class:`Factory` provider.
    """

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is None:
            raise Error('{0} must be overridden before calling'.format(self))
        return self.__last_overriding(*args, **kwargs)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if not isinstance(provider, Factory):
            raise Error('{0} must be overridden only by '
                        '{1} providers'.format(self, Factory))
        return super(AbstractFactory, self).override(provider)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable's call."""
        raise NotImplementedError('Abstract provider forward providing logic '
                                  'to overriding provider')


cdef class FactoryDelegate(Delegate):
    """Factory delegate injects delegating factory "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, factory):
        """Initializer.

        :param factory: Value that have to be provided.
        :type factory: object
        """
        if isinstance(factory, Factory) is False:
            raise Error('{0} can wrap only {1} providers'.format(
                self.__class__, Factory))
        super(Delegate, self).__init__(factory)


cdef class FactoryAggregate(Provider):
    """Factory providers aggregate.

    :py:class:`FactoryAggregate` is an aggregate of :py:class:`Factory`
    providers.

    :py:class:`FactoryAggregate` is a delegated provider, meaning that it is
    injected "as is".

    All aggregated factories could be retrieved as a read-only
    dictionary :py:attr:`FactoryAggregate.factories` or just as an attribute of
    :py:class:`FactoryAggregate`.
    """

    __IS_DELEGATED__ = True

    def __init__(self, **factories):
        """Initializer.

        :param factories: Dictionary of aggregate factories.
        :type factories: dict[str, :py:class:`Factory`]
        """
        for factory in factories.values():
            if isinstance(factory, Factory) is False:
                raise Error(
                    '{0} can aggregate only instances of {1}, given - {2}'
                    .format(self.__class__, Factory, factory))
        self.__factories = factories
        super(FactoryAggregate, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        cdef FactoryAggregate copied

        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = self.__class__()
        copied.__factories = deepcopy(self.__factories, memo)

        self._copy_overridings(copied, memo)

        return copied

    def __call__(self, factory_name, *args, **kwargs):
        """Create new object using factory with provided name.

        Callable interface implementation.
        """
        return self.__get_factory(factory_name)(*args, **kwargs)

    def __getattr__(self, factory_name):
        """Return aggregated factory."""
        return self.__get_factory(factory_name)

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.factories)

    @property
    def factories(self):
        """Return dictionary of factories, read-only."""
        return self.__factories

    def override(self, _):
        """Override provider with another provider.

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        raise Error(
            '{0} providers could not be overridden'.format(self.__class__))

    cdef Factory __get_factory(self, str factory_name):
        if factory_name not in self.__factories:
            raise NoSuchProviderError(
                '{0} does not contain factory with name {1}'.format(
                    self, factory_name))
        return <Factory> self.__factories[factory_name]


cdef class BaseSingleton(Provider):
    """Base class of singleton providers."""

    provided_type = None

    def __init__(self, provides, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        if (self.__class__.provided_type and
                not issubclass(provides, self.__class__.provided_type)):
            raise Error('{0} can provide only {1} instances'.format(
                self.__class__, self.__class__.provided_type))

        self.__instantiator = Factory(provides, *args, **kwargs)

        super(BaseSingleton, self).__init__()

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self,
                                  provides=self.__instantiator.cls)

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        cls = self.cls
        if isinstance(cls, Provider):
            cls = deepcopy(cls, memo)

        copied = self.__class__(cls,
                                *deepcopy(self.args, memo),
                                **deepcopy(self.kwargs, memo))
        copied.set_attributes(**deepcopy(self.attributes, memo))

        self._copy_overridings(copied, memo)

        return copied

    @property
    def cls(self):
        """Return provided type."""
        return self.__instantiator.cls

    @property
    def args(self):
        """Return positional argument injections."""
        return self.__instantiator.args

    def add_args(self, *args):
        """Add __init__ positional argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_args(*args)
        return self

    def set_args(self, *args):
        """Set __init__ positional argument injections.

        Existing __init__ positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_args(*args)
        return self

    def clear_args(self):
        """Drop __init__ positional argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_args()
        return self

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        return self.__instantiator.kwargs

    def add_kwargs(self, **kwargs):
        """Add __init__ keyword argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_kwargs(**kwargs)
        return self

    def set_kwargs(self, **kwargs):
        """Set __init__ keyword argument injections.

        Existing __init__ keyword argument injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_kwargs(**kwargs)
        return self

    def clear_kwargs(self):
        """Drop __init__ keyword argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_kwargs()
        return self

    @property
    def attributes(self):
        """Return attribute injections."""
        return self.__instantiator.attributes

    def add_attributes(self, **kwargs):
        """Add attribute injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_attributes(**kwargs)
        return self

    def set_attributes(self, **kwargs):
        """Set attribute injections.

        Existing attribute injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_attributes(**kwargs)
        return self

    def clear_attributes(self):
        """Drop attribute injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_attributes()
        return self

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        raise NotImplementedError()


cdef class Singleton(BaseSingleton):
    """Singleton provider returns same instance on every call.

    :py:class:`Singleton` provider creates instance once and returns it on
    every call. :py:class:`Singleton` extends :py:class:`Factory`, so, please
    follow :py:class:`Factory` documentation for getting familiar with
    injections syntax.

    Retrieving of provided instance can be performed via calling
    :py:class:`Singleton` object:

    .. code-block:: python

        singleton = Singleton(SomeClass)
        some_object = singleton()

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    def __init__(self, provides, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        self.__storage = None
        super(Singleton, self).__init__(provides, *args, **kwargs)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        self.__storage = None

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        if self.__storage is None:
            self.__storage = __factory_call(self.__instantiator,
                                            args, kwargs)
        return self.__storage


cdef class DelegatedSingleton(Singleton):
    """Delegated singleton is injected "as is".

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    __IS_DELEGATED__ = True


cdef class ThreadSafeSingleton(BaseSingleton):
    """Thread-safe singleton provider."""

    storage_lock = threading.RLock()
    """Storage reentrant lock.

    :type: :py:class:`threading.RLock`
    """

    def __init__(self, provides, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        self.__storage = None
        self.__storage_lock = self.__class__.storage_lock
        super(ThreadSafeSingleton, self).__init__(provides, *args, **kwargs)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        self.__storage = None

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        with self.__storage_lock:
            if self.__storage is None:
                self.__storage = __factory_call(self.__instantiator,
                                                args, kwargs)
        return self.__storage


cdef class DelegatedThreadSafeSingleton(ThreadSafeSingleton):
    """Delegated thread-safe singleton is injected "as is".

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    __IS_DELEGATED__ = True


cdef class ThreadLocalSingleton(BaseSingleton):
    """Thread-local singleton provides single objects in scope of thread.

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    def __init__(self, provides, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        self.__storage = threading.local()
        super(ThreadLocalSingleton, self).__init__(provides, *args, **kwargs)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        del self.__storage.instance

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        cdef object instance

        try:
            instance = self.__storage.instance
        except AttributeError:
            instance = __factory_call(self.__instantiator, args, kwargs)
            self.__storage.instance = instance
        finally:
            return instance


cdef class DelegatedThreadLocalSingleton(ThreadLocalSingleton):
    """Delegated thread-local singleton is injected "as is".

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    __IS_DELEGATED__ = True


cdef class AbstractSingleton(BaseSingleton):
    """Abstract singleton provider.

    :py:class:`AbstractSingleton` is a :py:class:`Singleton` provider that must
    be explicitly overridden before calling.

    Overriding of :py:class:`AbstractSingleton` is possible only by another
    :py:class:`BaseSingleton` provider.
    """

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is None:
            raise Error('{0} must be overridden before calling'.format(self))
        return self.__last_overriding(*args, **kwargs)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if not isinstance(provider, BaseSingleton):
            raise Error('{0} must be overridden only by '
                        '{1} providers'.format(self, BaseSingleton))
        return super(AbstractSingleton, self).override(provider)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        if self.__last_overriding is None:
            raise Error('{0} must be overridden before calling'.format(self))
        return self.__last_overriding.reset()


cdef class SingletonDelegate(Delegate):
    """Singleton delegate injects delegating singleton "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, singleton):
        """Initializer.

        :param singleton: Value that have to be provided.
        :type singleton: py:class:`BaseSingleton`
        """
        if isinstance(singleton, BaseSingleton) is False:
            raise Error('{0} can wrap only {1} providers'.format(
                self.__class__, BaseSingleton))
        super(Delegate, self).__init__(singleton)


cdef class Injection(object):
    """Abstract injection class."""


cdef class PositionalInjection(Injection):
    """Positional injection class."""

    def __init__(self, value):
        """Initializer."""
        self.__value = value
        self.__is_provider = <int>is_provider(value)
        self.__is_delegated = <int>is_delegated(value)
        self.__call = <int>(self.__is_provider == 1 and
                            self.__is_delegated == 0)
        super(PositionalInjection, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied
        return self.__class__(deepcopy(self.__value, memo))

    def get_value(self):
        """Return injection value."""
        return __get_value(self)

    def get_original_value(self):
        """Return original value."""
        return self.__value


cdef class NamedInjection(Injection):
    """Keyword injection class."""

    def __init__(self, name, value):
        """Initializer."""
        self.__name = name
        self.__value = value
        self.__is_provider = <int>is_provider(value)
        self.__is_delegated = <int>is_delegated(value)
        self.__call = <int>(self.__is_provider == 1 and
                            self.__is_delegated == 0)
        super(NamedInjection, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied
        return self.__class__(deepcopy(self.__name, memo),
                              deepcopy(self.__value, memo))

    def get_name(self):
        """Return injection value."""
        return __get_name(self)

    def get_value(self):
        """Return injection value."""
        return __get_value(self)

    def get_original_value(self):
        """Return original value."""
        return self.__value


@cython.boundscheck(False)
@cython.wraparound(False)
cpdef tuple parse_positional_injections(tuple args):
    """Parse positional injections."""
    cdef list injections = list()
    cdef int args_len = len(args)

    cdef int index
    cdef object arg
    cdef PositionalInjection injection

    for index in range(args_len):
        arg = args[index]
        injection = PositionalInjection(arg)
        injections.append(injection)

    return tuple(injections)


@cython.boundscheck(False)
@cython.wraparound(False)
cpdef tuple parse_named_injections(dict kwargs):
    """Parse named injections."""
    cdef list injections = list()

    cdef object name
    cdef object arg
    cdef NamedInjection injection

    for name, arg in kwargs.items():
        injection = NamedInjection(name, arg)
        injections.append(injection)

    return tuple(injections)


cpdef bint is_provider(object instance):
    """Check if instance is provider instance.

    :param instance: Instance to be checked.
    :type instance: object

    :rtype: bool
    """
    return (not isinstance(instance, CLASS_TYPES) and
            getattr(instance, '__IS_PROVIDER__', False) is True)


cpdef object ensure_is_provider(object instance):
    """Check if instance is provider instance and return it.

    :param instance: Instance to be checked.
    :type instance: object

    :raise: :py:exc:`dependency_injector.errors.Error` if provided instance is
            not provider.

    :rtype: :py:class:`dependency_injector.providers.Provider`
    """
    if not is_provider(instance):
        raise Error('Expected provider instance, '
                    'got {0}'.format(str(instance)))
    return instance


cpdef bint is_delegated(object instance):
    """Check if instance is delegated provider.

    :param instance: Instance to be checked.
    :type instance: object

    :rtype: bool
    """
    return (not isinstance(instance, CLASS_TYPES) and
            getattr(instance, '__IS_DELEGATED__', False) is True)


cpdef str represent_provider(object provider, object provides):
    """Return string representation of provider.

    :param provider: Provider object
    :type provider: :py:class:`dependency_injector.providers.Provider`

    :param provides: Object that provider provides
    :type provider: object

    :return: String representation of provider
    :rtype: str
    """
    return '<{provider}({provides}) at {address}>'.format(
        provider='.'.join((provider.__class__.__module__,
                           provider.__class__.__name__)),
        provides=repr(provides) if provides is not None else '',
        address=hex(id(provider)))


cpdef object deepcopy(object instance, dict memo=None):
    """Return full copy of provider or container with providers."""
    if memo is None:
        memo = dict()

    __add_sys_streams(memo)

    return copy.deepcopy(instance, memo)

def __add_sys_streams(memo):
    """Add system streams to memo dictionary.

    This helps to avoid copying of system streams while making a deepcopy of
    objects graph.
    """
    memo[id(sys.stdin)] = sys.stdin
    memo[id(sys.stdout)] = sys.stdout
    memo[id(sys.stderr)] = sys.stderr
