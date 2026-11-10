FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY app.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out .
ENV ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["dotnet", "app.dll"]
